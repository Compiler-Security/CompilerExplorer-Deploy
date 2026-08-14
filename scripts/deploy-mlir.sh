#!/usr/bin/env bash
# 原子发布 MLIR 构建产物；目录须含 bin/mlir-opt 与 bin/mlir-translate。
# 用法：deploy-mlir.sh <构建产物目录> [构建标识]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${CE_COMPILERS_ROOT:-}" && -f "${REPO_ROOT}/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"; set +a
fi
: "${CE_COMPILERS_ROOT:?未设置 CE_COMPILERS_ROOT。请 cp .env.example .env 并填入实际路径，或用环境变量传入。}"

CE_COMPILERS_ROOT="$(readlink -m "${CE_COMPILERS_ROOT}")"
if [[ -z "${CE_COMPILERS_ROOT}" || "${CE_COMPILERS_ROOT}" == "/" ]]; then
  echo "错误: CE_COMPILERS_ROOT 为空或为根目录，已拒绝（防止 rm -rf 误删）。" >&2
  exit 1
fi

LINK_NAME="mlir-custom"

SRC="${1:?用法: deploy-mlir.sh <构建产物目录> [构建标识]}"
BUILD_ID="${2:-$(date +%Y%m%d%H%M%S)}"
[[ "${BUILD_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
  || { echo "错误: 构建标识只能含字母、数字、点、下划线和连字符，且不能以标点开头。" >&2; exit 1; }
TARGET="${CE_COMPILERS_ROOT}/${LINK_NAME}.${BUILD_ID}"

[[ -x "${SRC}/bin/mlir-opt" ]] || { echo "错误: ${SRC}/bin/mlir-opt 不存在或不可执行"; exit 1; }
[[ -x "${SRC}/bin/mlir-translate" ]] || { echo "错误: ${SRC}/bin/mlir-translate 不存在或不可执行"; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "错误: 缺少 rsync。" >&2; exit 1; }

echo ">> 发布 ${SRC} -> ${TARGET}"
mkdir -p "${CE_COMPILERS_ROOT}"
command -v flock >/dev/null 2>&1 \
  || { echo "错误: 缺少 flock（通常由 util-linux 提供），无法安全串行发布。" >&2; exit 1; }
exec 9>"${CE_COMPILERS_ROOT}/.update.lock"
flock 9
[[ ! -e "${TARGET}" && ! -L "${TARGET}" ]] \
  || { echo "错误: ${TARGET} 已存在；构建标识必须唯一，以免覆盖可回滚版本。" >&2; exit 1; }
PARTIAL="${CE_COMPILERS_ROOT}/.${LINK_NAME}.partial.$$"
trap 'rm -rf -- "${PARTIAL}"' EXIT
rsync -a --delete "${SRC}/" "${PARTIAL}/"
mv -T "${PARTIAL}" "${TARGET}"
touch "${TARGET}"  # 用发布时间排序回滚版本。
trap - EXIT

if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
  chcon -R -t container_file_t "${TARGET}" || true
fi

TMP_LINK="${CE_COMPILERS_ROOT}/.${LINK_NAME}.tmp.$$"
ln -s "$(basename "${TARGET}")" "${TMP_LINK}"
mv -Tf "${TMP_LINK}" "${CE_COMPILERS_ROOT}/${LINK_NAME}"

echo ">> 已切换 ${LINK_NAME} -> $(basename "${TARGET}")"
"${CE_COMPILERS_ROOT}/${LINK_NAME}/bin/mlir-opt" --version | head -1 || true

# shellcheck source=lib-vm.sh
source "${REPO_ROOT}/scripts/lib-vm.sh"
restart_ce_in_vm

# 清理旧 build：保留当前版本和最近 3 个回滚版本。
cd "${CE_COMPILERS_ROOT}"
ls -1dt ${LINK_NAME}.* 2>/dev/null | tail -n +5 | while read -r old; do
  [[ "${old}" == "${LINK_NAME}".* && "${old}" != */* && -d "${old}" ]] \
    || { echo ">> 跳过非常规项 ${old}"; continue; }
  [[ "$(readlink -f "${LINK_NAME}")" == "$(readlink -f "${old}")" ]] && continue
  echo ">> 清理旧版本 ${old}"
  rm -rf -- "${old}"
done

echo ">> 完成。"
