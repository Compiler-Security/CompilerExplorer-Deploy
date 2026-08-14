#!/usr/bin/env bash
# =============================================================================
# update-ce.sh —— 升级 CompilerExplorer 本体（CE 跑在 QEMU VM 内）。
#
#   用法:
#     update-ce.sh gh-18910        # 升级到指定 CE release tag
#
#   机制：把 .env 里的 CE_REF 改成新 tag，再 force-recreate qemu 容器。
#   VM 的 entrypoint 检测到 CE_REF 变化会重建 VM 磁盘（保留已缓存的云镜像底包，
#   不重下），cloud-init 随即按新 tag 重新装配 CE。期间 CE 有几分钟停机。
#
#   查看可用 tag: https://github.com/compiler-explorer/compiler-explorer/tags
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NEW_REF="${1:?用法: update-ce.sh <ce-tag>  (如 gh-18910)}"

# 写 .env 的 CE_REF（没有这条就追加）
touch .env
if grep -q '^CE_REF=' .env; then
  sed -i -E "s/^CE_REF=.*/CE_REF=${NEW_REF}/" .env
else
  echo "CE_REF=${NEW_REF}" >> .env
fi
echo ">> .env 中 CE_REF=${NEW_REF}"

echo ">> 重建 qemu 容器（entrypoint 将检测到 CE_REF 变化并重新装配 VM 内的 CE）"
docker compose -f docker-compose.vm.yml up -d --force-recreate qemu

cat <<EOF
>> 已触发。VM 正在按 ${NEW_REF} 重新装配 CE（构建需几分钟）。
>> 跟进进度:
     docker compose -f docker-compose.vm.yml logs -f qemu
>> 装配完成后验证:
     curl http://127.0.0.1:10240/api/version
EOF
