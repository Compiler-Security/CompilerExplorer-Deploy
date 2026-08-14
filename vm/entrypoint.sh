#!/usr/bin/env bash
# 准备并启动 QEMU/KVM VM；CE_REF 变化或新 FORCE_REPROVISION 令牌会重建 overlay。
set -euo pipefail

VM_CPUS="${VM_CPUS:-8}"
VM_MEM_MB="${VM_MEM_MB:-8192}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
DEFAULT_VM_IMAGE_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
DEFAULT_VM_IMAGE_SHA256_URL="https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS"
VM_IMAGE_URL="${VM_IMAGE_URL:-${DEFAULT_VM_IMAGE_URL}}"
VM_IMAGE_SHA256="${VM_IMAGE_SHA256:-}"
VM_IMAGE_SHA256_URL="${VM_IMAGE_SHA256_URL:-}"
if [[ -z "${VM_IMAGE_SHA256_URL}" && "${VM_IMAGE_URL}" == "${DEFAULT_VM_IMAGE_URL}" ]]; then
  VM_IMAGE_SHA256_URL="${DEFAULT_VM_IMAGE_SHA256_URL}"
fi
CE_REF="${CE_REF:-gh-18904}"
FORCE_REPROVISION="${FORCE_REPROVISION:-0}"
NODE_VERSION="${NODE_VERSION:-}"
NODE_SHA256="${NODE_SHA256:-}"
COMPILERS_SRC="${COMPILERS_SRC:?需指定工具链目录(容器内路径)}"
REPO_SRC="${REPO_SRC:?需指定仓库目录(容器内路径)}"
FWD_PORT="${FWD_PORT:-10240}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-/vm/ssh/ce_vm_key.pub}"

DISK_DIR=/vm/disk
BASE="${DISK_DIR}/base.img"
DISK="${DISK_DIR}/ce-vm.qcow2"
SEED="${DISK_DIR}/seed.iso"
REF_MARKER="${DISK_DIR}/.ce_ref"
BASE_SOURCE_MARKER="${DISK_DIR}/.base_source"
REPROVISION_MARKER="${DISK_DIR}/.reprovision_token"
MON_SOCK="${DISK_DIR}/monitor.sock"
mkdir -p "${DISK_DIR}"

[[ "${CE_REF}" =~ ^gh-[0-9]+$ ]] \
  || { echo "错误: CE_REF 格式应为 gh-<数字>。" >&2; exit 2; }
[[ "${FORCE_REPROVISION}" =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "错误: FORCE_REPROVISION 只能含字母、数字、点、下划线和连字符。" >&2; exit 2; }
[[ -z "${NODE_VERSION}" || "${NODE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "错误: NODE_VERSION 必须是纯版本号（例如 22.22.1）。" >&2; exit 2; }
if [[ -n "${NODE_VERSION}" ]]; then
  IFS=. read -r node_major node_minor node_patch <<< "${NODE_VERSION}"
  (( 10#${node_major} > 22 \
     || (10#${node_major} == 22 && 10#${node_minor} > 22) \
     || (10#${node_major} == 22 && 10#${node_minor} == 22 && 10#${node_patch} >= 1) )) \
    || { echo "错误: 当前 CE 要求 Node >= 22.22.1。" >&2; exit 2; }
fi
[[ -z "${NODE_SHA256}" || "${NODE_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: NODE_SHA256 必须是 64 位十六进制。" >&2; exit 2; }
[[ -z "${VM_IMAGE_SHA256}" || "${VM_IMAGE_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: VM_IMAGE_SHA256 必须是 64 位十六进制。" >&2; exit 2; }
NODE_SHA256="${NODE_SHA256,,}"
VM_IMAGE_SHA256="${VM_IMAGE_SHA256,,}"
IMAGE_SOURCE_ID="$(printf '%s\n%s\n%s\n' "${VM_IMAGE_URL}" "${VM_IMAGE_SHA256}" "${VM_IMAGE_SHA256_URL}" \
  | sha256sum | awk '{print $1}')"

if [[ ! -c /dev/kvm ]]; then
  echo "错误: 容器内没有 /dev/kvm。请在 compose 里挂 --device /dev/kvm，" >&2
  echo "      并确认宿主机有 KVM（若宿主机本身是 VM，需开嵌套虚拟化）。" >&2
  exit 1
fi

if [[ -f "${BASE}" && -f "${BASE_SOURCE_MARKER}" \
      && "$(cat "${BASE_SOURCE_MARKER}")" != "${IMAGE_SOURCE_ID}" ]]; then
  echo ">> 云镜像来源或校验值已变化：刷新基础镜像并重建 VM 磁盘"
  rm -f "${DISK}" "${BASE}" "${BASE_SOURCE_MARKER}"
fi

REPROVISION_TOKEN_TO_RECORD=""
if [[ "${FORCE_REPROVISION}" != "0" \
      && (! -f "${REPROVISION_MARKER}" || "$(cat "${REPROVISION_MARKER}")" != "${FORCE_REPROVISION}") ]]; then
  echo ">> 收到新的 FORCE_REPROVISION 请求（${FORCE_REPROVISION}）：重建 VM 磁盘一次"
  rm -f "${DISK}"
  REPROVISION_TOKEN_TO_RECORD="${FORCE_REPROVISION}"
elif [[ "${FORCE_REPROVISION}" != "0" ]]; then
  echo ">> FORCE_REPROVISION 请求 ${FORCE_REPROVISION} 已执行过，本次不重复删盘"
fi

if [[ -f "${DISK}" && -f "${REF_MARKER}" && "$(cat "${REF_MARKER}")" != "${CE_REF}" ]]; then
  echo ">> CE_REF 变化 ($(cat "${REF_MARKER}") -> ${CE_REF})，重建 VM 磁盘以重新装配"
  rm -f "${DISK}"
elif [[ -f "${DISK}" && ! -f "${REF_MARKER}" ]]; then
  echo ">> 现有 VM 磁盘缺少版本标记：为避免复用未知状态，重新装配"
  rm -f "${DISK}"
fi

if [[ -f "${DISK}" && ! -f "${BASE}" ]]; then
  echo ">> 基础镜像缺失，现有 overlay 无法使用：重新创建 VM 磁盘"
  rm -f "${DISK}"
fi

resolve_image_sha256() {
  if [[ -n "${VM_IMAGE_SHA256}" ]]; then
    printf '%s\n' "${VM_IMAGE_SHA256}"
    return 0
  fi
  if [[ -z "${VM_IMAGE_SHA256_URL}" ]]; then
    return 0
  fi

  local sums image_name expected
  image_name="${VM_IMAGE_URL##*/}"
  echo ">> 读取镜像校验和 ${VM_IMAGE_SHA256_URL}" >&2
  sums="$(curl -fsSL --retry 3 "${VM_IMAGE_SHA256_URL}")"
  expected="$(printf '%s\n' "${sums}" \
    | awk -v name="${image_name}" '$2 == name || $2 == "*" name {found=$1} END {if (found) print found}')"
  [[ "${expected}" =~ ^[[:xdigit:]]{64}$ ]] \
    || { echo "错误: 在 ${VM_IMAGE_SHA256_URL} 中找不到 ${image_name} 的 SHA256" >&2; exit 1; }
  printf '%s\n' "${expected,,}"
}

# 兼容旧版没有来源标记的 base.img。
if [[ -f "${BASE}" && ! -f "${BASE_SOURCE_MARKER}" ]]; then
  expected="$(resolve_image_sha256)"
  if [[ -n "${expected}" ]]; then
    actual="$(sha256sum "${BASE}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
      echo ">> 旧基础镜像与当前校验值不符：重新下载并重建 VM 磁盘"
      rm -f "${DISK}" "${BASE}"
    else
      echo ">> 旧基础镜像 SHA256 校验通过，继续复用"
      printf '%s\n' "${IMAGE_SOURCE_ID}" > "${BASE_SOURCE_MARKER}"
    fi
  else
    echo ">> 警告: 旧基础镜像没有来源标记且无可用哈希；继续复用。" >&2
    printf '%s\n' "${IMAGE_SOURCE_ID}" > "${BASE_SOURCE_MARKER}"
  fi
fi

if [[ ! -f "${DISK}" ]]; then
  if [[ ! -f "${BASE}" ]]; then
    expected="$(resolve_image_sha256)"
    echo ">> 下载云镜像 ${VM_IMAGE_URL}"
    curl -fSL --retry 3 -o "${BASE}.partial" "${VM_IMAGE_URL}"
    if [[ -n "${expected}" ]]; then
      actual="$(sha256sum "${BASE}.partial" | awk '{print $1}')"
      [[ "${actual}" == "${expected}" ]] \
        || { echo "错误: 云镜像 SHA256 不匹配（期望 ${expected} 实际 ${actual}）"; rm -f "${BASE}.partial"; exit 1; }
      echo ">> 云镜像 SHA256 校验通过"
    else
      echo ">> 警告: 未提供 VM_IMAGE_SHA256/VM_IMAGE_SHA256_URL，云镜像未校验完整性" >&2
    fi
    mv "${BASE}.partial" "${BASE}"
    printf '%s\n' "${IMAGE_SOURCE_ID}" > "${BASE_SOURCE_MARKER}"
  fi
  echo ">> 基于基础镜像创建 overlay 磁盘 ${DISK}（上限 ${VM_DISK_SIZE}）"
  DISK_PARTIAL="${DISK}.partial"
  rm -f "${DISK_PARTIAL}"
  if ! qemu-img create -f qcow2 -b "${BASE}" -F qcow2 "${DISK_PARTIAL}" "${VM_DISK_SIZE}"; then
    rm -f "${DISK_PARTIAL}"
    exit 1
  fi
  mv "${DISK_PARTIAL}" "${DISK}"
fi
if [[ -n "${REPROVISION_TOKEN_TO_RECORD}" ]]; then
  printf '%s\n' "${REPROVISION_TOKEN_TO_RECORD}" > "${REPROVISION_MARKER}"
fi

echo ">> 生成 cloud-init seed（CE_REF=${CE_REF}）"
TMPCD="$(mktemp -d)"
trap 'rm -rf "${TMPCD}"' EXIT
cp /vm/cloud-init/meta-data "${TMPCD}/meta-data"
PUBKEY=""
if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
  read -r key_type key_data _ < "${SSH_PUBKEY_FILE}" || true
  if [[ "${key_type:-}" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)$ \
        && "${key_data:-}" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    PUBKEY="${key_type} ${key_data}"
  elif [[ -s "${SSH_PUBKEY_FILE}" ]]; then
    echo "错误: SSH 公钥格式无效: ${SSH_PUBKEY_FILE}" >&2
    exit 1
  fi
fi
if [[ -n "${PUBKEY}" ]]; then
  echo ">> 已注入 SSH 公钥（宿主可 ssh -p ${SSH_FWD_PORT} ce@127.0.0.1 进 VM）"
else
  echo ">> 未提供 SSH 公钥：跳过 SSH 管理通道"
fi
awk -v ce_ref="${CE_REF}" -v node_version="${NODE_VERSION}" -v node_sha="${NODE_SHA256}" -v pubkey="${PUBKEY}" '
  /^__SSH_AUTHORIZED_KEYS__$/ {
    if (pubkey != "") {
      print "    ssh_authorized_keys:"
      print "      - " pubkey
    }
    next
  }
  {
    gsub(/__CE_REF__/, ce_ref)
    gsub(/__NODE_VERSION__/, node_version)
    gsub(/__NODE_SHA256__/, node_sha)
    print
  }
' /vm/cloud-init/user-data > "${TMPCD}/user-data"
genisoimage -output "${SEED}" -volid cidata -joliet -rock "${TMPCD}/user-data" "${TMPCD}/meta-data"
rm -rf "${TMPCD}"
trap - EXIT
echo "${CE_REF}" > "${REF_MARKER}"

echo ">> 启动 VM：${VM_CPUS}C / ${VM_MEM_MB}MB；CE=hostfwd:${FWD_PORT}->10240；SSH=hostfwd:${SSH_FWD_PORT}->22"
echo ">> 9p 共享: compilers=${COMPILERS_SRC} (ro), cerepo=${REPO_SRC} (ro)"

shutdown() {
  echo ">> 收到停止信号，向 VM 发 ACPI powerdown（优雅关机）"
  echo "system_powerdown" | socat - "UNIX-CONNECT:${MON_SOCK}" 2>/dev/null || true
  for _ in $(seq 1 30); do
    [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null || return 0
    sleep 1
  done
  echo ">> 优雅关机超时，强制结束" >&2
  kill -9 "${QEMU_PID}" 2>/dev/null || true
}
QEMU_PID=""
trap shutdown TERM INT
rm -f "${MON_SOCK}"
trap 'rm -f "${MON_SOCK}"' EXIT

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
  -display none -vga none -serial stdio &
QEMU_PID=$!
wait "${QEMU_PID}"
