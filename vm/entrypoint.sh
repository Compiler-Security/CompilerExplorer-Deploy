#!/usr/bin/env bash
# =============================================================================
# QEMU/KVM 启动 CompilerExplorer 隔离 VM（CE 直接跑在 VM 里，无内层 docker）。
#   首启：下载云镜像 -> 建 qcow2 overlay -> 生成 cloud-init seed -> 起 VM。
#   之后：复用已有磁盘直接起（VM 内状态持久）。
#   CE_REF 变化时：自动重建 overlay 重新装配 CE（基础镜像缓存，不重下）。
#
# 环境变量（compose 注入）：
#   VM_CPUS / VM_MEM_MB   VM 规格（默认 8C / 8192MB）
#   VM_DISK_SIZE          磁盘上限（默认 40G，qcow2 按需增长）
#   VM_IMAGE_URL          云镜像（默认 Ubuntu 24.04 noble amd64）
#   CE_REF                CE 版本 tag（默认 gh-18904）；变了会触发重新装配
#   COMPILERS_SRC         容器内看到的工具链目录（9p 共享给 VM，只读）
#   REPO_SRC              容器内看到的本仓库目录（9p 共享给 VM，只读）
#   FWD_PORT              容器内监听端口（hostfwd 到 VM 的 10240；默认 10240）
#   SSH_FWD_PORT          容器内 SSH 转发端口（hostfwd 到 VM 的 22；默认 2222）
# =============================================================================
set -euo pipefail

VM_CPUS="${VM_CPUS:-8}"
VM_MEM_MB="${VM_MEM_MB:-8192}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_IMAGE_URL="${VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
CE_REF="${CE_REF:-gh-18904}"
COMPILERS_SRC="${COMPILERS_SRC:?需指定工具链目录(容器内路径)}"
REPO_SRC="${REPO_SRC:?需指定仓库目录(容器内路径)}"
FWD_PORT="${FWD_PORT:-10240}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-/vm/ssh/ce_vm_key.pub}"   # 可选；用于宿主 SSH 进 VM 重启 CE

DISK_DIR=/vm/disk
BASE="${DISK_DIR}/base.img"
DISK="${DISK_DIR}/ce-vm.qcow2"
SEED="${DISK_DIR}/seed.iso"
REF_MARKER="${DISK_DIR}/.ce_ref"
mkdir -p "${DISK_DIR}"

# KVM 是硬依赖：没有就直接失败，绝不悄悄退化成软件模拟（TCG 编译会慢到不可用）。
if [[ ! -c /dev/kvm ]]; then
  echo "错误: 容器内没有 /dev/kvm。请在 compose 里挂 --device /dev/kvm，" >&2
  echo "      并确认宿主机有 KVM（若宿主机本身是 VM，需开嵌套虚拟化）。" >&2
  exit 1
fi

# CE_REF 变化 -> 重建 overlay（保留基础镜像），让 cloud-init 重新装配新 CE 版本。
if [[ -f "${DISK}" && -f "${REF_MARKER}" && "$(cat "${REF_MARKER}")" != "${CE_REF}" ]]; then
  echo ">> CE_REF 变化 ($(cat "${REF_MARKER}") -> ${CE_REF})，重建 VM 磁盘以重新装配"
  rm -f "${DISK}"
fi

# 首启（或重建）：准备基础镜像与 overlay 磁盘。
if [[ ! -f "${DISK}" ]]; then
  if [[ ! -f "${BASE}" ]]; then
    echo ">> 下载云镜像 ${VM_IMAGE_URL}"
    curl -fSL --retry 3 -o "${BASE}.partial" "${VM_IMAGE_URL}"
    mv "${BASE}.partial" "${BASE}"
  fi
  echo ">> 基于基础镜像创建 overlay 磁盘 ${DISK}（上限 ${VM_DISK_SIZE}）"
  qemu-img create -f qcow2 -b "${BASE}" -F qcow2 "${DISK}" "${VM_DISK_SIZE}"
fi

# 生成 cloud-init seed：注入 CE_REF 与（可选）SSH 公钥。
echo ">> 生成 cloud-init seed（CE_REF=${CE_REF}）"
TMPCD="$(mktemp -d)"
cp /vm/cloud-init/meta-data "${TMPCD}/meta-data"
PUBKEY=""
[[ -f "${SSH_PUBKEY_FILE}" ]] && PUBKEY="$(cat "${SSH_PUBKEY_FILE}")"
if [[ -n "${PUBKEY}" ]]; then
  sed "s#__SSH_PUBKEY__#${PUBKEY}#" /vm/cloud-init/user-data > "${TMPCD}/user-data"
  echo ">> 已注入 SSH 公钥（宿主可 ssh -p ${SSH_FWD_PORT} ce@127.0.0.1 进 VM 管理 CE）"
else
  sed "/__SSH_PUBKEY__/d" /vm/cloud-init/user-data > "${TMPCD}/user-data"
  echo ">> 未提供 SSH 公钥（${SSH_PUBKEY_FILE} 不存在）：跳过 SSH 管理通道"
fi
sed -i "s#__CE_REF__#${CE_REF}#g" "${TMPCD}/user-data"
genisoimage -output "${SEED}" -volid cidata -joliet -rock "${TMPCD}/user-data" "${TMPCD}/meta-data"
rm -rf "${TMPCD}"
echo "${CE_REF}" > "${REF_MARKER}"

echo ">> 启动 VM：${VM_CPUS}C / ${VM_MEM_MB}MB；CE=hostfwd:${FWD_PORT}->10240；SSH=hostfwd:${SSH_FWD_PORT}->22"
echo ">> 9p 共享: compilers=${COMPILERS_SRC} (ro), cerepo=${REPO_SRC} (ro)"

exec qemu-system-x86_64 \
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
  -display none -vga none -serial mon:stdio
