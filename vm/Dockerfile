# syntax=docker/dockerfile:1
# QEMU/KVM 运行时；guest 由 cloud-init 装配。
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils genisoimage curl ca-certificates socat \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /share/compilers /share/sshpub \
      /share/repo/config /share/repo/scripts /share/repo/vm

WORKDIR /vm
VOLUME ["/vm/disk"]

# 启动逻辑与 cloud-init 从只读仓库挂载读取；修改后不必重建 QEMU 工具镜像。
ENTRYPOINT ["/bin/bash", "/share/repo/vm/entrypoint.sh"]
