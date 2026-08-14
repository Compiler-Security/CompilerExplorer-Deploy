#!/usr/bin/env bash
# =============================================================================
# deploy-mlir.sh —— 由 MLIR Jenkins job 在每次 build 成功后调用。
#   把新的 MLIR 构建产物原子地发布为 CE 使用的 mlir-custom，并重启 CE。
#
# 用法（Jenkins 里）：
#   /path/to/scripts/deploy-mlir.sh <构建产物目录> [构建标识]
# 例：
#   deploy-mlir.sh "$WORKSPACE/build/install" "$BUILD_NUMBER"
#
# 产物目录需含 bin/mlir-opt、bin/mlir-translate（及运行所需 lib/）。
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}"
# 工具链根：环境变量优先；否则读仓库根 .env；再不行报错。
if [[ -z "${CE_COMPILERS_ROOT:-}" && -f "${REPO_ROOT}/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"; set +a
fi
: "${CE_COMPILERS_ROOT:?未设置 CE_COMPILERS_ROOT。请 cp .env.example .env 并填入实际路径，或用环境变量传入。}"

# 安全护栏（最小爆炸半径）：规范化并拒绝空/根等危险工具链根，防止后续 rm -rf 误伤。
CE_COMPILERS_ROOT="$(readlink -m "${CE_COMPILERS_ROOT}")"
if [[ -z "${CE_COMPILERS_ROOT}" || "${CE_COMPILERS_ROOT}" == "/" ]]; then
  echo "错误: CE_COMPILERS_ROOT 为空或为根目录，已拒绝（防止 rm -rf 误删）。" >&2
  exit 1
fi

LINK_NAME="mlir-custom"

SRC="${1:?用法: deploy-mlir.sh <构建产物目录> [构建标识]}"
BUILD_ID="${2:-$(date +%Y%m%d%H%M%S)}"
TARGET="${CE_COMPILERS_ROOT}/${LINK_NAME}.${BUILD_ID}"

[[ -x "${SRC}/bin/mlir-opt" ]] || { echo "错误: ${SRC}/bin/mlir-opt 不存在或不可执行"; exit 1; }

echo ">> 发布 ${SRC} -> ${TARGET}"
mkdir -p "${CE_COMPILERS_ROOT}"
# 先同步到临时目标目录，避免半成品被符号链接指到。
rm -rf -- "${TARGET}.partial"
rsync -a --delete "${SRC}/" "${TARGET}.partial/"
mv -T "${TARGET}.partial" "${TARGET}"

# SELinux (Enforcing) 下，给新目录打上容器可读标签，确保重启后的 CE 容器能读到。
if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
  chcon -R -t container_file_t "${TARGET}" || true
fi

# 原子切换符号链接：先建临时链接再 rename。
ln -sfn "${TARGET}" "${CE_COMPILERS_ROOT}/.${LINK_NAME}.tmp"
mv -T "${CE_COMPILERS_ROOT}/.${LINK_NAME}.tmp" "${CE_COMPILERS_ROOT}/${LINK_NAME}"

echo ">> 已切换 ${LINK_NAME} -> ${TARGET}"
"${CE_COMPILERS_ROOT}/${LINK_NAME}/bin/mlir-opt" --version | head -1 || true

# 重启 CE，刷新其启动时缓存的 --version 显示（新编译本就会用新二进制）。
echo ">> 重启 CE"
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" restart ce

# 清理旧 build，只保留最近 3 个（不含当前链接指向的）。
cd "${CE_COMPILERS_ROOT}"
ls -1dt ${LINK_NAME}.* 2>/dev/null | tail -n +4 | while read -r old; do
  # 只删当前目录下名为 mlir-custom.* 的真实目录（防误删其它内容）
  [[ "${old}" == "${LINK_NAME}".* && "${old}" != */* && -d "${old}" ]] \
    || { echo ">> 跳过非常规项 ${old}"; continue; }
  [[ "$(readlink -f "${LINK_NAME}")" == "$(readlink -f "${old}")" ]] && continue
  echo ">> 清理旧版本 ${old}"
  rm -rf -- "${old}"
done

echo ">> 完成。"
