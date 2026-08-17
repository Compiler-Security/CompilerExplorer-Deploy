#!/usr/bin/env bash
# 原子发布 P4 工具链 tarball：解压为 p4mlir-<short_hash>/ 并将 p4-latest 软链指向它。
# 用法：deploy-p4.sh <p4mlir-<short_hash>.tar.gz|p4mlir-<short_hash>.tar.zst>
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LINK_NAME="p4-latest"
ARCHIVE="${1:?用法: deploy-p4.sh <p4mlir-<short_hash>.tar.gz|p4mlir-<short_hash>.tar.zst>}"
[[ "$#" -eq 1 ]] || { echo "用法: $0 <p4mlir-<short_hash>.tar.gz|p4mlir-<short_hash>.tar.zst>" >&2; exit 2; }
[[ -f "${ARCHIVE}" ]] || { echo "错误: 归档不存在: ${ARCHIVE}" >&2; exit 1; }

archive_name="$(basename "${ARCHIVE}")"
[[ "${archive_name}" =~ ^p4mlir-([A-Za-z0-9][A-Za-z0-9._-]{0,127})\.tar\.(gz|zst)$ ]] \
  || { echo "错误: 归档文件名必须是 p4mlir-<short_hash>.tar.gz 或 p4mlir-<short_hash>.tar.zst: ${archive_name}" >&2; exit 1; }
BUILD_ID="${BASH_REMATCH[1]}"
ARCHIVE_FORMAT="${BASH_REMATCH[2]}"
TARGET="${CE_COMPILERS_ROOT}/p4mlir-${BUILD_ID}"

required_exes="bin/p4c bin/p4mlir-opt bin/p4mlir-translate bin/p4mlir-to-json bin/mlir-translate bin/clang bin/clang++ bin/opt bin/llc bin/llvm-objdump bin/llvm-cxxfilt"

require_commands tar
[[ "${ARCHIVE_FORMAT}" == "gz" ]] || require_commands zstd
lock_toolchains

[[ ! -e "${TARGET}" && ! -L "${TARGET}" ]] \
  || { echo "错误: ${TARGET} 已存在；构建标识必须唯一，以免覆盖可回滚版本。" >&2; exit 1; }

echo ">> 发布 ${archive_name} -> ${TARGET}"
TOOLCHAIN_PARTIAL="${CE_COMPILERS_ROOT}/.${LINK_NAME}.partial.$$"
trap toolchain_cleanup EXIT
mkdir -p "${TOOLCHAIN_PARTIAL}"
if [[ "${ARCHIVE_FORMAT}" == "gz" ]]; then
  tar -xzf "${ARCHIVE}" -C "${TOOLCHAIN_PARTIAL}"
else
  zstd -dc "${ARCHIVE}" | tar -x -C "${TOOLCHAIN_PARTIAL}"
fi

# 兼容两种打包方式：内容直接在根，或包含单个顶层目录。
if [[ ! -d "${TOOLCHAIN_PARTIAL}/bin" ]]; then
  entries=("${TOOLCHAIN_PARTIAL}"/*)
  [[ "${#entries[@]}" -eq 1 && -d "${entries[0]}" ]] \
    || { echo "错误: 归档结构无法识别，缺少 bin/ 目录。" >&2; exit 1; }
  mv "${entries[0]}" "${TOOLCHAIN_PARTIAL}.inner"
  rm -rf -- "${TOOLCHAIN_PARTIAL}"
  mv "${TOOLCHAIN_PARTIAL}.inner" "${TOOLCHAIN_PARTIAL}"
fi

toolchain_has_executables "${TOOLCHAIN_PARTIAL}" "${required_exes}" \
  || { echo "错误: 归档缺少必要可执行文件（${required_exes}）。" >&2; exit 1; }

mv -T "${TOOLCHAIN_PARTIAL}" "${TARGET}"
TOOLCHAIN_PARTIAL=""
touch "${TARGET}"

if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
  chcon -R -t container_file_t "${TARGET}" || true
fi

point_toolchain_link "${LINK_NAME}" "${TARGET}"
"${CE_COMPILERS_ROOT}/${LINK_NAME}/bin/p4c" --version | head -1 || true
DID_CHANGE=1
finish_toolchain_update "P4 工具链"

# 保留当前版本和最近 3 个回滚版本。
cd "${CE_COMPILERS_ROOT}"
ls -1dt p4mlir-* 2>/dev/null | tail -n +5 | while read -r old; do
  [[ "${old}" == p4mlir-* && "${old}" != */* && -d "${old}" ]] \
    || { echo ">> 跳过非常规项 ${old}"; continue; }
  [[ "$(readlink -f "${LINK_NAME}")" == "$(readlink -f "${old}")" ]] && continue
  echo ">> 清理旧版本 ${old}"
  rm -rf -- "${old}"
done
