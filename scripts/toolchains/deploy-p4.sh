#!/usr/bin/env bash
# 原子发布 P4 工具链 tarball：解压为 p4mlir-<build_id>/ 并将 p4-latest 软链指向它。
# 标准 Jenkins build_id 为 <build-number>-<short-hash>。
# 用法：deploy-p4.sh <p4mlir-<build_id>.tar.gz|p4mlir-<build_id>.tar.zst>
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LINK_NAME="p4-latest"
MAX_BUILDS="${P4_TOOLCHAIN_MAX_BUILDS:-4}"
ARCHIVE="${1:?用法: deploy-p4.sh <p4mlir-<build_id>.tar.gz|p4mlir-<build_id>.tar.zst>}"
[[ "$#" -eq 1 ]] || { echo "用法: $0 <p4mlir-<build_id>.tar.gz|p4mlir-<build_id>.tar.zst>" >&2; exit 2; }
[[ -f "${ARCHIVE}" ]] || { echo "错误: 归档不存在: ${ARCHIVE}" >&2; exit 1; }
[[ "${MAX_BUILDS}" =~ ^[0-9]+$ ]] \
  || { echo "错误: P4_TOOLCHAIN_MAX_BUILDS 必须是非负整数: ${MAX_BUILDS}" >&2; exit 2; }
MAX_BUILDS=$((10#${MAX_BUILDS}))

archive_name="$(basename "${ARCHIVE}")"
[[ "${archive_name}" =~ ^p4mlir-([A-Za-z0-9][A-Za-z0-9._-]{0,127})\.tar\.(gz|zst)$ ]] \
  || { echo "错误: 归档文件名必须是 p4mlir-<build_id>.tar.gz 或 p4mlir-<build_id>.tar.zst: ${archive_name}" >&2; exit 1; }
BUILD_ID="${BASH_REMATCH[1]}"
ARCHIVE_FORMAT="${BASH_REMATCH[2]}"
TARGET="${CE_COMPILERS_ROOT}/p4mlir-${BUILD_ID}"

required_exes="bin/p4c bin/p4mlir-opt bin/p4mlir-translate bin/p4mlir-to-json bin/mlir-translate bin/opt bin/llc bin/llvm-objdump bin/llvm-cxxfilt"
required_files="share/p4c/p4include/core.p4"

prune_p4_builds() {
  local max_builds="$1" current_target remaining index record _mtime old old_path
  local -a records=() ordered_builds=()

  if ((max_builds == 0)); then
    echo ">> P4 build 自动清理已禁用"
    return
  fi

  shopt -s nullglob
  for old_path in "${CE_COMPILERS_ROOT}"/p4mlir-*; do
    [[ -d "${old_path}" && ! -L "${old_path}" ]] || continue
    records+=("$(find "${old_path}" -maxdepth 0 -printf '%T@')"$'\t'"${old_path##*/}")
  done
  shopt -u nullglob
  if ((${#records[@]} <= max_builds)); then
    return 0
  fi

  mapfile -t ordered_builds < <(printf '%s\n' "${records[@]}" | sort -t $'\t' -k1,1nr -k2,2r)
  current_target="$(readlink -f "${CE_COMPILERS_ROOT}/${LINK_NAME}")"
  remaining="${#ordered_builds[@]}"

  for ((index = ${#ordered_builds[@]} - 1; index >= 0 && remaining > max_builds; index--)); do
    record="${ordered_builds[index]}"
    IFS=$'\t' read -r _mtime old <<< "${record}"
    [[ "${old}" == p4mlir-* && "${old}" != */* ]] \
      || { echo ">> 跳过非常规项 ${old}"; continue; }
    old_path="${CE_COMPILERS_ROOT}/${old}"
    [[ -d "${old_path}" && ! -L "${old_path}" ]] || continue
    [[ "$(readlink -f "${old_path}")" == "${current_target}" ]] && continue

    echo ">> 清理旧版本 ${old}"
    # 旧版本可能由其他用户（手动部署）或只读权限的 tarball 产生；
    # 清理失败不应让已成功切换的发布失败，仅告警并保留。
    chmod -R u+rwX -- "${old_path}" 2>/dev/null || true
    if rm -rf -- "${old_path}"; then
      remaining=$((remaining - 1))
    else
      echo ">> 警告: 清理 ${old} 失败（属主可能不是部署用户），请用属主或 root 手动删除。" >&2
    fi
  done

  if ((remaining > max_builds)); then
    echo ">> 警告: 当前仍有 ${remaining} 个 P4 build，超过配置上限 ${max_builds}。" >&2
  fi
}

require_commands tar find sort
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
for required_file in ${required_files}; do
  [[ -f "${TOOLCHAIN_PARTIAL}/${required_file}" ]] \
    || { echo "错误: 归档缺少必要文件 ${required_file}。" >&2; exit 1; }
done

mv -T "${TOOLCHAIN_PARTIAL}" "${TARGET}"
TOOLCHAIN_PARTIAL=""
touch "${TARGET}"
# 无论 tarball 记录的目录权限如何，确保部署用户以后能清理该版本。
chmod -R u+rwX "${TARGET}"

if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
  chcon -R -t container_file_t "${TARGET}" || true
fi

point_toolchain_link "${LINK_NAME}" "${TARGET}"
"${CE_COMPILERS_ROOT}/${LINK_NAME}/bin/p4c" --version | head -1 || true
DID_CHANGE=1
prune_p4_builds "${MAX_BUILDS}"
finish_toolchain_update "P4 工具链"
