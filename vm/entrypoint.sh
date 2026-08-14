#!/usr/bin/env bash
# =============================================================================
# QEMU/KVM 启动 CompilerExplorer 隔离 VM（CE 直接跑在 VM 里，无内层 docker）。
#   首启：下载云镜像 -> 建 qcow2 overlay -> 生成 cloud-init seed -> 起 VM。
#   之后：复用已有磁盘直接起（VM 内状态持久）。
#   CE_REF 变化 或 FORCE_REPROVISION=1：重建 overlay 重新装配（云镜像底包缓存，不重下）。
#
# 环境变量（compose 注入）：
#   VM_CPUS / VM_MEM_MB   VM 规格（默认 8C / 8192MB）
#   VM_DISK_SIZE          磁盘上限（默认 40G，qcow2 按需增长）
#   VM_IMAGE_URL          云镜像（默认钉到 Ubuntu 24.04 noble 某快照）
#   VM_IMAGE_SHA256       可选：云镜像 SHA256，钉了就强制校验
#   CE_REF                CE 版本 tag（默认 gh-18904）；变了触发重新装配
#   FORCE_REPROVISION     =1 时无条件重建 VM 磁盘（用于装配失败后的恢复 / 改配置 / 加公钥）
#   COMPILERS_SRC/REPO_SRC  容器内看到的工具链/仓库目录（9p 共享给 VM，只读）
#   FWD_PORT / SSH_FWD_PORT  CE/SSH 的 hostfwd 端口（默认 10240 / 2222）
# =============================================================================
set -euo pipefail

VM_CPUS="${VM_CPUS:-8}"
VM_MEM_MB="${VM_MEM_MB:-8192}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
# 钉到具体快照目录，避免 noble/current 漂移；要更新就连 SHA256 一起换。
VM_IMAGE_URL="${VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/20250805/noble-server-cloudimg-amd64.img}"
VM_IMAGE_SHA256="${VM_IMAGE_SHA256:-}"
CE_REF="${CE_REF:-gh-18904}"
FORCE_REPROVISION="${FORCE_REPROVISION:-0}"
COMPILERS_SRC="${COMPILERS_SRC:?需指定工具链目录(容器内路径)}"
REPO_SRC="${REPO_SRC:?需指定仓库目录(容器内路径)}"
FWD_PORT="${FWD_PORT:-10240}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-/vm/ssh/ce_vm_key.pub}"   # 可选；宿主 SSH 进 VM 管理 CE

DISK_DIR=/vm/disk
BASE="${DISK_DIR}/base.img"
DISK="${DISK_DIR}/ce-vm.qcow2"
SEED="${DISK_DIR}/seed.iso"
REF_MARKER="${DISK_DIR}/.ce_ref"
MON_SOCK="${DISK_DIR}/monitor.sock"
mkdir -p "${DISK_DIR}"

# KVM 是硬依赖：没有就直接失败，绝不悄悄退化成软件模拟（TCG 编译会慢到不可用）。
if [[ ! -c /dev/kvm ]]; then
  echo "错误: 容器内没有 /dev/kvm。请在 compose 里挂 --device /dev/kvm，" >&2
  echo "      并确认宿主机有 KVM（若宿主机本身是 VM，需开嵌套虚拟化）。" >&2
  exit 1
fi

# ---- 决定是否重建 VM 磁盘 ------------------------------------------------------
if [[ "${FORCE_REPROVISION}" == "1" && -f "${DISK}" ]]; then
  echo ">> FORCE_REPROVISION=1：重建 VM 磁盘"
  rm -f "${DISK}"
elif [[ -f "${DISK}" && -f "${REF_MARKER}" && "$(cat "${REF_MARKER}")" != "${CE_REF}" ]]; then
  echo ">> CE_REF 变化 ($(cat "${REF_MARKER}") -> ${CE_REF})，重建 VM 磁盘以重新装配"
  rm -f "${DISK}"
fi

# ---- 准备基础镜像与 overlay ----------------------------------------------------
if [[ ! -f "${DISK}" ]]; then
  if [[ ! -f "${BASE}" ]]; then
    echo ">> 下载云镜像 ${VM_IMAGE_URL}"
    curl -fSL --retry 3 -o "${BASE}.partial" "${VM_IMAGE_URL}"
    if [[ -n "${VM_IMAGE_SHA256}" ]]; then
      actual="$(sha256sum "${BASE}.partial" | awk '{print $1}')"
      [[ "${actual}" == "${VM_IMAGE_SHA256}" ]] \
        || { echo "错误: 云镜像 SHA256 不匹配（期望 ${VM_IMAGE_SHA256} 实际 ${actual}）"; rm -f "${BASE}.partial"; exit 1; }
      echo ">> 云镜像 SHA256 校验通过"
    else
      echo ">> 警告: 未钉 VM_IMAGE_SHA256，云镜像未校验完整性" >&2
    fi
    mv "${BASE}.partial" "${BASE}"
  fi
  echo ">> 基于基础镜像创建 overlay 磁盘 ${DISK}（上限 ${VM_DISK_SIZE}）"
  qemu-img create -f qcow2 -b "${BASE}" -F qcow2 "${DISK}" "${VM_DISK_SIZE}"
fi

# ---- 生成 cloud-init seed（注入 CE_REF / SSH 公钥）-----------------------------
echo ">> 生成 cloud-init seed（CE_REF=${CE_REF}）"
TMPCD="$(mktemp -d)"
cp /vm/cloud-init/meta-data "${TMPCD}/meta-data"
PUBKEY=""
[[ -f "${SSH_PUBKEY_FILE}" ]] && PUBKEY="$(cat "${SSH_PUBKEY_FILE}")"
if [[ -n "${PUBKEY}" ]]; then
  sed "s#__SSH_PUBKEY__#${PUBKEY}#" /vm/cloud-init/user-data > "${TMPCD}/user-data"
  echo ">> 已注入 SSH 公钥（宿主可 ssh -p ${SSH_FWD_PORT} ce@127.0.0.1 进 VM）"
else
  sed "/__SSH_PUBKEY__/d" /vm/cloud-init/user-data > "${TMPCD}/user-data"
  echo ">> 未提供 SSH 公钥：跳过 SSH 管理通道"
fi
sed -i "s#__CE_REF__#${CE_REF}#g" "${TMPCD}/user-data"
genisoimage -output "${SEED}" -volid cidata -joliet -rock "${TMPCD}/user-data" "${TMPCD}/meta-data"
rm -rf "${TMPCD}"
echo "${CE_REF}" > "${REF_MARKER}"

echo ">> 启动 VM：${VM_CPUS}C / ${VM_MEM_MB}MB；CE=hostfwd:${FWD_PORT}->10240；SSH=hostfwd:${SSH_FWD_PORT}->22"
echo ">> 9p 共享: compilers=${COMPILERS_SRC} (ro), cerepo=${REPO_SRC} (ro)"

# ---- 优雅关机：docker stop -> SIGTERM -> 经 human-monitor 发 ACPI powerdown -----
shutdown() {
  echo ">> 收到停止信号，向 VM 发 ACPI powerdown（优雅关机）"
  echo "system_powerdown" | socat - "UNIX-CONNECT:${MON_SOCK}" 2>/dev/null || true
  # 等 QEMU 退出；超时则强杀
  for _ in $(seq 1 30); do kill -0 "${QEMU_PID}" 2>/dev/null || return 0; sleep 1; done
  echo ">> 优雅关机超时，强制结束" >&2
  kill -9 "${QEMU_PID}" 2>/dev/null || true
}
trap shutdown TERM INT

qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -cpu host \
  -smp "${VM_CPUS}" \
  -m "${VM_MEM_MB}" \
  -drive file="${DISK}",if=virtio,format=qcow2 \
  -drive file="${SEED}",if=virtio,media=cdrom,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp::"${FWD_PORT}"-:10240,hostfwd=tcp::"${SSH_FWD_PORT}"-:22 \
  -device virtio-net-pci,netdev=n0 \
  -fsdev local,id=fscomp,path="${COMPILERS_SRC}",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=fscomp,mount_tag=compilers \
  -fsdev local,id=fsrepo,path="${REPO_SRC}",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=fsrepo,mount_tag=cerepo \
  -monitor unix:"${MON_SOCK}",server,nowait \
  -display none -vga none -serial mon:stdio &
QEMU_PID=$!
wait "${QEMU_PID}"
