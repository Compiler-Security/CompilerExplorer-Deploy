# syntax=docker/dockerfile:1
# QEMU/KVM 运行时；guest 由 cloud-init 装配。
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils genisoimage curl ca-certificates socat \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /vm
COPY --chmod=0755 entrypoint.sh /vm/entrypoint.sh
COPY cloud-init/ /vm/cloud-init/

VOLUME ["/vm/disk"]

ENTRYPOINT ["/vm/entrypoint.sh"]
