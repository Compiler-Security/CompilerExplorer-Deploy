#!/usr/bin/env bash
# 原子发布 MLIR 构建产物；目录须含 bin/mlir-opt 与 bin/mlir-translate。
# 用法：deploy-mlir.sh <构建产物目录> [构建标识]
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LINK_NAME="mlir-custom"
SRC="${1:?用法: deploy-mlir.sh <构建产物目录> [构建标识]}"
BUILD_ID="${2:-$(date +%Y%m%d%H%M%S)}"
[[ "$#" -le 2 ]] || { echo "用法: $0 <构建产物目录> [构建标识]" >&2; exit 2; }
[[ "${BUILD_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
  || { echo "错误: 构建标识只能含字母、数字、点、下划线和连字符，且不能以标点开头。" >&2; exit 1; }
TARGET="${CE_COMPILERS_ROOT}/${LINK_NAME}.${BUILD_ID}"

[[ -x "${SRC}/bin/mlir-opt" ]] || { echo "错误: ${SRC}/bin/mlir-opt 不存在或不可执行。" >&2; exit 1; }
[[ -x "${SRC}/bin/mlir-translate" ]] || { echo "错误: ${SRC}/bin/mlir-translate 不存在或不可执行。" >&2; exit 1; }
require_commands rsync
lock_toolchains

[[ ! -e "${TARGET}" && ! -L "${TARGET}" ]] \
  || { echo "错误: ${TARGET} 已存在；构建标识必须唯一，以免覆盖可回滚版本。" >&2; exit 1; }

echo ">> 发布 ${SRC} -> ${TARGET}"
TOOLCHAIN_PARTIAL="${CE_COMPILERS_ROOT}/.${LINK_NAME}.partial.$$"
trap toolchain_cleanup EXIT
rsync -a --delete "${SRC}/" "${TOOLCHAIN_PARTIAL}/"
mv -T "${TOOLCHAIN_PARTIAL}" "${TARGET}"
TOOLCHAIN_PARTIAL=""
touch "${TARGET}"

if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
  chcon -R -t container_file_t "${TARGET}" || true
fi

point_toolchain_link "${LINK_NAME}" "${TARGET}"
"${CE_COMPILERS_ROOT}/${LINK_NAME}/bin/mlir-opt" --version | head -1 || true
DID_CHANGE=1
finish_toolchain_update "MLIR"

# 保留当前版本和最近 3 个回滚版本。
cd "${CE_COMPILERS_ROOT}"
ls -1dt ${LINK_NAME}.* 2>/dev/null | tail -n +5 | while read -r old; do
  [[ "${old}" == "${LINK_NAME}".* && "${old}" != */* && -d "${old}" ]] \
    || { echo ">> 跳过非常规项 ${old}"; continue; }
  [[ "$(readlink -f "${LINK_NAME}")" == "$(readlink -f "${old}")" ]] && continue
  echo ">> 清理旧版本 ${old}"
  rm -rf -- "${old}"
done
