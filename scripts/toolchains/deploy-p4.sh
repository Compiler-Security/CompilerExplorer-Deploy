#!/usr/bin/env bash
# 原子发布 P4 工具链 tarball：解压为 p4mlir-<build_id>/ 并将 p4-latest 软链指向它。
# 标准 Jenkins build_id 为 <yyyyMMddHHmm>-<build-number>-<commit>。
# 用法：deploy-p4.sh <p4mlir-<build_id>.tar.gz|p4mlir-<build_id>.tar.zst>
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=p4-builds.sh
source "${TOOLCHAINS_DIR}/p4-builds.sh"

LINK_NAME="p4-latest"
ARCHIVE="${1:?用法: deploy-p4.sh <p4mlir-<build_id>.tar.gz|p4mlir-<build_id>.tar.zst>}"
[[ "$#" -eq 1 ]] || { echo "用法: $0 <p4mlir-<build_id>.tar.gz|p4mlir-<build_id>.tar.zst>" >&2; exit 2; }
[[ -f "${ARCHIVE}" ]] || { echo "错误: 归档不存在: ${ARCHIVE}" >&2; exit 1; }
p4_load_retention_days "${CE_COMPILERS_ROOT}"

archive_name="$(basename "${ARCHIVE}")"
[[ "${archive_name}" =~ ^p4mlir-([A-Za-z0-9][A-Za-z0-9._-]{0,127})\.tar\.(gz|zst)$ ]] \
  || { echo "错误: 归档文件名必须是 p4mlir-<build_id>.tar.gz 或 p4mlir-<build_id>.tar.zst: ${archive_name}" >&2; exit 1; }
BUILD_ID="${BASH_REMATCH[1]}"
ARCHIVE_FORMAT="${BASH_REMATCH[2]}"
TARGET="${CE_COMPILERS_ROOT}/p4mlir-${BUILD_ID}"

required_exes="${P4_BUILD_REQUIRED_EXES[*]}"
required_files="${P4_BUILD_REQUIRED_FILES[*]}"

persist_p4_retention_days() {
  local policy_file="${CE_COMPILERS_ROOT}/${P4_RETENTION_POLICY_FILE}"
  TOOLCHAIN_CONFIG_TEMP="$(mktemp "${policy_file}.tmp.XXXXXX")"
  printf '%s\n' "${P4_RETENTION_DAYS}" > "${TOOLCHAIN_CONFIG_TEMP}"
  chmod 0644 "${TOOLCHAIN_CONFIG_TEMP}"
  mv -Tf -- "${TOOLCHAIN_CONFIG_TEMP}" "${policy_file}"
  TOOLCHAIN_CONFIG_TEMP=""
  if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
    chcon -t container_file_t "${policy_file}" || true
  fi
}

select_and_prune_p4_builds() {
  local old_path old
  p4_select_builds "${CE_COMPILERS_ROOT}"
  [[ -n "${P4_LATEST_BUILD_PATH}" ]] \
    || { echo "错误: P4 保留策略没有选出可用 build。" >&2; exit 1; }

  point_toolchain_link "${LINK_NAME}" "${P4_LATEST_BUILD_PATH}"
  for old_path in "${P4_REJECTED_BUILD_PATHS[@]}"; do
    old="${old_path##*/}"
    [[ "${old}" == p4mlir-* && "${old}" != */* \
       && "$(dirname "${old_path}")" == "${CE_COMPILERS_ROOT}" \
       && -d "${old_path}" && ! -L "${old_path}" ]] \
      || { echo ">> 跳过非常规项 ${old_path}"; continue; }
    [[ "$(readlink -f "${old_path}")" == "$(readlink -f "${CE_COMPILERS_ROOT}/${LINK_NAME}")" ]] && continue

    echo ">> 清理未保留版本 ${old}"
    # 旧版本可能由其他用户（手动部署）或只读权限的 tarball 产生；
    # 清理失败不应让已成功切换的发布失败，仅告警并保留。
    chmod -R u+rwX -- "${old_path}" 2>/dev/null || true
    if ! rm -rf -- "${old_path}"; then
      echo ">> 警告: 清理 ${old} 失败（属主可能不是部署用户），请用属主或 root 手动删除。" >&2
    fi
  done

  echo ">> P4 保留策略：${P4_RETENTION_DAYS} 天，选中 ${#P4_SELECTED_BUILD_PATHS[@]} 个 build"
}

require_commands date find readlink sort tar
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

persist_p4_retention_days
select_and_prune_p4_builds
"${CE_COMPILERS_ROOT}/${LINK_NAME}/bin/p4c" --version | head -1 || true
DID_CHANGE=1
finish_toolchain_update "P4 工具链"
