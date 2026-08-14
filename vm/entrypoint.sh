#!/usr/bin/env bash
# =============================================================================
# QEMU/KVM 启动 CompilerExplorer 隔离 VM。
#   首启：下载云镜像 -> 建 qcow2 overlay -> 生成 cloud-init seed -> 起 VM。
#   之后：复用已有磁盘直接起（VM 内状态持久）。
#
# 环境变量（compose 注入）：
#   VM_CPUS / VM_MEM_MB   VM 规格（默认 8C / 8192MB）
#   VM_DISK_SIZE          磁盘上限（默认 40G，qcow2 按需增长）
#   VM_IMAGE_URL          云镜像（默认 Ubuntu 24.04 noble amd64）
#   COMPILERS_SRC         容器内看到的工具链目录（9p 共享给 VM，只读）
#   REPO_SRC              容器内看到的本仓库目录（9p 共享给 VM，只读）
#   FWD_PORT              容器内监听端口（hostfwd 到 VM 的 10240；默认 10240）
# =============================================================================
set -euo pipefail

VM_CPUS="${VM_CPUS:-8}"
VM_MEM_MB="${VM_MEM_MB:-8192}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_IMAGE_URL="${VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
COMPILERS_SRC="${COMPILERS_SRC:?需指定工具链目录(容器内路径)}"
REPO_SRC="${REPO_SRC:?需指定仓库目录(容器内路径)}"
FWD_PORT="${FWD_PORT:-10240}"

DISK_DIR=/vm/disk
BASE="${DISK_DIR}/base.img"
DISK="${DISK_DIR}/ce-vm.qcow2"
SEED="${DISK_DIR}/seed.iso"
mkdir -p "${DISK_DIR}"

# KVM 是硬依赖：没有就直接失败，绝不悄悄退化成软件模拟（TCG 编译会慢到不可用）。
if [[ ! -c /dev/kvm ]]; then
  echo "错误: 容器内没有 /dev/kvm。请在 compose 里挂 --device /dev/kvm，" >&2
  echo "      并确认宿主机有 KVM（若宿主机本身是 VM，需开嵌套虚拟化）。" >&2
  exit 1
fi

# 首启：准备基础镜像与 overlay 磁盘。
if [[ ! -f "${DISK}" ]]; then
  if [[ ! -f "${BASE}" ]]; then
    echo ">> 下载云镜像 ${VM_IMAGE_URL}"
    curl -fSL --retry 3 -o "${BASE}.partial" "${VM_IMAGE_URL}"
    mv "${BASE}.partial" "${BASE}"
  fi
  echo ">> 基于基础镜像创建 overlay 磁盘 ${DISK}（上限 ${VM_DISK_SIZE}）"
  qemu-img create -f qcow2 -b "${BASE}" -F qcow2 "${DISK}" "${VM_DISK_SIZE}"
fi

# 每次启动都重建 seed（cloud-init 的 runcmd 只在实例首启执行；改 cloud-init 需重建磁盘，
# 见 README 的「VM 重配」说明）。
echo ">> 生成 cloud-init seed"
genisoimage -output "${SEED}" -volid cidata -joliet -rock \
  /vm/cloud-init/user-data /vm/cloud-init/meta-data

echo ">> 启动 VM：${VM_CPUS}C / ${VM_MEM_MB}MB，hostfwd 容器:${FWD_PORT} -> VM:10240"
echo ">> 9p 共享: compilers=${COMPILERS_SRC} (ro), cerepo=${REPO_SRC} (ro)"

exec qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -cpu host \
  -smp "${VM_CPUS}" \
  -m "${VM_MEM_MB}" \
  -drive file="${DISK}",if=virtio,format=qcow2 \
  -drive file="${SEED}",if=virtio,media=cdrom,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp::"${FWD_PORT}"-:10240 \
  -device virtio-net-pci,netdev=n0 \
  -fsdev local,id=fscomp,path="${COMPILERS_SRC}",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=fscomp,mount_tag=compilers \
  -fsdev local,id=fsrepo,path="${REPO_SRC}",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=fsrepo,mount_tag=cerepo \
  -display none -vga none -serial mon:stdio
