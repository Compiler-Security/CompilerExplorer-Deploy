# syntax=docker/dockerfile:1
# =============================================================================
# QEMU/KVM 运行时镜像 —— 在共享宿主机的 Docker 里起一个隔离 VM，CE 跑在 VM 内。
#   宿主机的唯一暴露面就是这个容器 + /dev/kvm；cgroup/AppArmor/userns 都不动宿主机。
# 仅含 QEMU 与云镜像工具，VM 的系统与 CE 栈由 cloud-init 在首启时装配。
# =============================================================================
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils genisoimage curl ca-certificates socat \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /vm
COPY entrypoint.sh /vm/entrypoint.sh
COPY cloud-init/ /vm/cloud-init/

# 磁盘与 seed 放 /vm/disk（compose 挂一个 named volume 持久化 qcow2）。
VOLUME ["/vm/disk"]

ENTRYPOINT ["/vm/entrypoint.sh"]
