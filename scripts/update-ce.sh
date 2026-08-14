#!/usr/bin/env bash
# =============================================================================
# update-ce.sh —— 更新 CompilerExplorer 本体（重建镜像并重启）。
#   CE 更新不频繁，手动跑即可；也可挂低频定时任务。
#
#   用法:
#     update-ce.sh gh-18910        # 升级到指定 release tag
#     update-ce.sh                 # 不带参数 = 用 Dockerfile 里的当前 CE_REF 重建
#
#   查看可用 tag: https://github.com/compiler-explorer/compiler-explorer/tags
# =============================================================================
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${COMPOSE_DIR}"

if [[ $# -ge 1 ]]; then
  NEW_REF="$1"
  echo ">> 将 Dockerfile 的 CE_REF 更新为 ${NEW_REF}"
  sed -i -E "s/^ARG CE_REF=.*/ARG CE_REF=${NEW_REF}/" Dockerfile
fi

CURRENT_REF="$(grep -E '^ARG CE_REF=' Dockerfile | cut -d= -f2)"
echo ">> 构建 CE 镜像 (CE_REF=${CURRENT_REF})"
docker compose build ce

echo ">> 重启 CE（滚动到新镜像）"
docker compose up -d ce

echo ">> 等待健康检查 ..."
for i in $(seq 1 30); do
  if docker compose exec -T ce node -e \
      "fetch('http://127.0.0.1:10240/healthcheck').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      >/dev/null 2>&1; then
    echo ">> CE 已就绪 (CE_REF=${CURRENT_REF})"
    exit 0
  fi
  sleep 2
done

echo "警告: 健康检查未在等待期内通过，请查看: docker compose logs ce" >&2
exit 1
