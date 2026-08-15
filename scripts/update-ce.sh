#!/usr/bin/env bash
# 更新 .env 的 CE_REF 并重建 QEMU overlay；用法：update-ce.sh gh-18910
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NEW_REF="${1:?用法: update-ce.sh <ce-tag>  (如 gh-18910)}"
[[ "${NEW_REF}" =~ ^gh-[0-9]+$ ]] \
  || { echo "错误: CE tag 格式应为 gh-<数字>（例如 gh-18910）。" >&2; exit 2; }
[[ -f .env ]] \
  || { echo "错误: 缺少 .env；请先 cp .env.example .env 并填写 CE_COMPILERS_ROOT。" >&2; exit 1; }
grep -qE '^CE_COMPILERS_ROOT=.+$' .env \
  || { echo "错误: .env 未设置 CE_COMPILERS_ROOT。" >&2; exit 1; }

if grep -q '^CE_REF=' .env; then
  sed -i -E "s/^CE_REF=.*/CE_REF=${NEW_REF}/" .env
else
  echo "CE_REF=${NEW_REF}" >> .env
fi
echo ">> .env 中 CE_REF=${NEW_REF}"

echo ">> 重建 qemu 容器（entrypoint 将检测到 CE_REF 变化并重新装配 VM 内的 CE）"
docker compose up -d --force-recreate qemu

cat <<EOF
>> 已触发。VM 正在按 ${NEW_REF} 重新装配 CE（构建需几分钟）。
>> 跟进进度:
     docker compose logs -f qemu
>> 装配完成后验证:
     curl http://127.0.0.1:10240/api/version

>> 提示：CE_REF 没变也想强制重新装配（加 SSH 公钥 / 上次装配失败恢复）：
     FORCE_REPROVISION="\$(date +%s%N)" docker compose up -d --force-recreate qemu
EOF
