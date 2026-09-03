#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

# shellcheck source=../scripts/toolchains/p4-builds.sh
source "${REPO_ROOT}/scripts/toolchains/p4-builds.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${message}: expected=${expected}, actual=${actual}"
}

assert_contains() {
  local needle="$1" file="$2"
  grep -Fqx -- "${needle}" "${file}" \
    || fail "${file} 缺少: ${needle}"
}

assert_array_contains() {
  local needle="$1"
  shift
  p4_array_contains "${needle}" "$@" || fail "数组缺少: ${needle}"
}

make_toolchain_dir() {
  local compiler_root="$1" build_id="$2" build_root
  local executable
  build_root="${compiler_root}/p4mlir-${build_id}"
  mkdir -p "${build_root}/bin" "${build_root}/share/p4c/p4include"
  for executable in \
    p4c p4mlir-opt p4mlir-translate p4mlir-to-json mlir-translate \
    opt llc llvm-objdump llvm-cxxfilt; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${build_root}/bin/${executable}"
    chmod +x "${build_root}/bin/${executable}"
  done
  printf '// test core.p4\n' > "${build_root}/share/p4c/p4include/core.p4"
}

make_archive() {
  local build_id="$1" format="${2:-zst}" stage archive
  local executable
  stage="${WORK_DIR}/stage-${build_id}-${format}"
  mkdir -p "${stage}/bin" "${stage}/share/p4c/p4include"
  for executable in \
    p4c p4mlir-opt p4mlir-translate p4mlir-to-json mlir-translate \
    opt llc llvm-objdump llvm-cxxfilt; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stage}/bin/${executable}"
    chmod +x "${stage}/bin/${executable}"
  done
  printf '// test core.p4\n' > "${stage}/share/p4c/p4include/core.p4"

  if [[ "${format}" == zst ]]; then
    archive="${WORK_DIR}/p4mlir-${build_id}.tar.zst"
    tar -cf - -C "${stage}" . | zstd -q -T1 -o "${archive}"
  else
    archive="${WORK_DIR}/p4mlir-${build_id}.tar.gz"
    tar -czf "${archive}" -C "${stage}" .
  fi
  printf '%s' "${archive}"
}

deploy() {
  local compiler_root="$1" build_id="$2" retention_days="$3" format="${4:-zst}" archive
  archive="$(make_archive "${build_id}" "${format}")"
  CE_COMPILERS_ROOT="${compiler_root}" P4_TOOLCHAIN_RETENTION_DAYS="${retention_days}" \
    bash "${REPO_ROOT}/scripts/toolchains/deploy-p4.sh" "${archive}" >/dev/null
}

count_builds() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -name 'p4mlir-*' | wc -l | tr -d '[:space:]'
}

# 新格式解析、旧格式 fallback，以及非法日期不应被误判为 dated build。
p4_parse_build_id 202609031430-108-b8b8b8b8
assert_eq dated "${P4_PARSED_KIND}" 'dated 类型'
assert_eq 20260903 "${P4_PARSED_DATE}" 'dated 日期'
assert_eq 108 "${P4_PARSED_BUILD_NUMBER}" 'dated build number'
assert_eq 2026-09-03 "${P4_PARSED_LABEL}" 'dated 菜单标签'
p4_parse_build_id 108-b8b8b8b8
assert_eq legacy "${P4_PARSED_KIND}" 'legacy 类型'
assert_eq 108 "${P4_PARSED_LABEL}" 'legacy 菜单标签'
p4_parse_build_id 202602301200-109-c9c9c9c9
assert_eq unknown "${P4_PARSED_KIND}" '非法日期类型'

# 日期窗口：每天只选最新一个，同分钟选 build number 最大者；legacy 填满剩余名额。
selection_root="${WORK_DIR}/selection"
mkdir -p "${selection_root}"
selection_ids=(
  202608272359-90-a0a0a0a0
  202608282300-91-a1a1a1a1
  202609010900-100-b0b0b0b0
  202609011800-101-b1b1b1b1
  202609021200-102-c2c2c2c2
  202609021200-103-c3c3c3c3
  202609030100-104-d4d4d4d4
  200-e0e0e0e0
  201-e1e1e1e1
  202-e2e2e2e2
  203-e3e3e3e3
  manual-release
)
for build_id in "${selection_ids[@]}"; do
  make_toolchain_dir "${selection_root}" "${build_id}"
done
mkdir -p "${selection_root}/p4mlir-202609031500-999-f9f9f9f9/bin"

P4_TOOLCHAIN_RETENTION_DAYS=7
p4_load_retention_days "${selection_root}"
p4_select_builds "${selection_root}"
unset P4_TOOLCHAIN_RETENTION_DAYS
expected_ids="$(printf '%s\n' \
  202609030100-104-d4d4d4d4 \
  202609021200-103-c3c3c3c3 \
  202609011800-101-b1b1b1b1 \
  202608282300-91-a1a1a1a1 \
  203-e3e3e3e3 \
  202-e2e2e2e2 \
  201-e1e1e1e1)"
assert_eq "${expected_ids}" "$(printf '%s\n' "${P4_SELECTED_BUILD_IDS[@]}")" '7 天选择结果'
assert_eq 7 "${#P4_SELECTED_BUILD_PATHS[@]}" 'dated + legacy 总数'
assert_eq "${selection_root}/p4mlir-202609030100-104-d4d4d4d4" "${P4_LATEST_BUILD_PATH}" '最新 dated build'
assert_array_contains "${selection_root}/p4mlir-202609010900-100-b0b0b0b0" "${P4_REJECTED_BUILD_PATHS[@]}"
assert_array_contains "${selection_root}/p4mlir-202609021200-102-c2c2c2c2" "${P4_REJECTED_BUILD_PATHS[@]}"
assert_array_contains "${selection_root}/p4mlir-202608272359-90-a0a0a0a0" "${P4_REJECTED_BUILD_PATHS[@]}"
assert_array_contains "${selection_root}/p4mlir-200-e0e0e0e0" "${P4_REJECTED_BUILD_PATHS[@]}"
assert_array_contains "${selection_root}/p4mlir-202609031500-999-f9f9f9f9" "${P4_REJECTED_BUILD_PATHS[@]}"

# 0 表示不限日期和总数，但同一天仍只保留一个。
P4_TOOLCHAIN_RETENTION_DAYS=0
p4_load_retention_days "${selection_root}"
p4_select_builds "${selection_root}"
unset P4_TOOLCHAIN_RETENTION_DAYS
assert_eq 10 "${#P4_SELECTED_BUILD_PATHS[@]}" '无限保留数量'
assert_eq 3 "${#P4_REJECTED_BUILD_PATHS[@]}" '无限保留仍执行每日去重并跳过不完整 build'

# 跨年窗口使用真实自然日。
year_root="${WORK_DIR}/year-boundary"
mkdir -p "${year_root}"
for build_id in \
  202612262300-300-a0a0a0a0 \
  202612272300-301-a1a1a1a1 \
  202612311200-302-a2a2a2a2 \
  202701021200-303-a3a3a3a3; do
  make_toolchain_dir "${year_root}" "${build_id}"
done
P4_TOOLCHAIN_RETENTION_DAYS=7
p4_load_retention_days "${year_root}"
p4_select_builds "${year_root}"
unset P4_TOOLCHAIN_RETENTION_DAYS
assert_eq 3 "${#P4_SELECTED_BUILD_PATHS[@]}" '跨年 7 天窗口'
assert_array_contains "${year_root}/p4mlir-202612262300-300-a0a0a0a0" "${P4_REJECTED_BUILD_PATHS[@]}"

# 生成器读取持久化策略，并且不注册同日旧版、窗口外版本或超额 legacy。
printf '7\n' > "${selection_root}/${P4_RETENTION_POLICY_FILE}"
ln -s p4mlir-202609030100-104-d4d4d4d4 "${selection_root}/p4-latest"
ce_home="${WORK_DIR}/ce"
mkdir -p "${ce_home}/etc/config"
sync_log="${WORK_DIR}/sync.log"
bash "${REPO_ROOT}/vm/sync-ce-config.sh" \
  "${ce_home}" "${REPO_ROOT}" "${selection_root}" >"${sync_log}" 2>&1

p4_config="${ce_home}/etc/config/p4.local.properties"
actual_translate_names="$(
  sed -n 's/^compiler\..*\.name=\(p4mlir-translate (.*)\)$/\1/p' "${p4_config}"
)"
expected_translate_names="$(printf '%s\n' \
  'p4mlir-translate (latest)' \
  'p4mlir-translate (2026-09-03)' \
  'p4mlir-translate (2026-09-02)' \
  'p4mlir-translate (2026-09-01)' \
  'p4mlir-translate (2026-08-28)' \
  'p4mlir-translate (203)' \
  'p4mlir-translate (202)' \
  'p4mlir-translate (201)')"
assert_eq "${expected_translate_names}" "${actual_translate_names}" '动态菜单顺序和标签'
grep -Fq '202609010900' "${p4_config}" && fail '同日旧版被注册'
grep -Fq '202608272359' "${p4_config}" && fail '窗口外 dated build 被注册'
grep -Fq '200-e0e0e0e0' "${p4_config}" && fail '超额 legacy build 被注册'
grep -Fq '202609031500' "${p4_config}" && fail '不完整 build 被注册'
grep -Fq '跳过不完整的 P4 build' "${sync_log}" || fail '不完整 build 没有告警'
for language in p4 mlir_p4 llvm_p4 llvm_mir_p4; do
  generated="${ce_home}/etc/config/${language}.local.properties"
  [[ -f "${generated}" && ! -L "${generated}" ]] || fail "${language} 配置未生成"
  grep -Fq '(latest)' "${generated}" || fail "${language} 缺少 latest 项"
  grep -Fq '(2026-09-03)' "${generated}" || fail "${language} 缺少 dated 项"
  grep -Fq '(203)' "${generated}" || fail "${language} 缺少 legacy 项"
done

# 部署集成：zst 新格式、gzip 旧格式、乱序部署、同分钟 tie-break 和策略持久化。
deploy_root="${WORK_DIR}/deploy"
mkdir -p "${deploy_root}"
deploy "${deploy_root}" 298-a8a8a8a8 3 gz
deploy "${deploy_root}" 299-a9a9a9a9 3 gz
deploy "${deploy_root}" 300-b0b0b0b0 3 gz
deploy "${deploy_root}" 202609031800-20-c0c0c0c0 3
assert_eq p4mlir-202609031800-20-c0c0c0c0 "$(readlink "${deploy_root}/p4-latest")" 'dated build 成为 latest'
deploy "${deploy_root}" 202609030900-21-c1c1c1c1 3
[[ ! -e "${deploy_root}/p4mlir-202609030900-21-c1c1c1c1" ]] || fail '乱序同日旧版未清理'
deploy "${deploy_root}" 202609031800-22-c2c2c2c2 3
assert_eq p4mlir-202609031800-22-c2c2c2c2 "$(readlink "${deploy_root}/p4-latest")" '同分钟 build number tie-break'
[[ ! -e "${deploy_root}/p4mlir-202609031800-20-c0c0c0c0" ]] || fail '同分钟较小 build 未清理'
deploy "${deploy_root}" 301-b1b1b1b1 3 gz
assert_eq 3 "$(count_builds "${deploy_root}")" 'dated + legacy 部署总数'
assert_eq p4mlir-202609031800-22-c2c2c2c2 "$(readlink "${deploy_root}/p4-latest")" 'legacy 乱序部署不覆盖 latest'
assert_eq 3 "$(tr -d '[:space:]' < "${deploy_root}/${P4_RETENTION_POLICY_FILE}")" '策略文件'

invalid_archive="$(make_archive 202609041200-400-d0d0d0d0)"
if CE_COMPILERS_ROOT="${deploy_root}" P4_TOOLCHAIN_RETENTION_DAYS=invalid \
  bash "${REPO_ROOT}/scripts/toolchains/deploy-p4.sh" "${invalid_archive}" >/dev/null 2>&1; then
  fail '非法 P4_TOOLCHAIN_RETENTION_DAYS 未被拒绝'
fi
[[ ! -e "${deploy_root}/p4mlir-202609041200-400-d0d0d0d0" ]] || fail '非法保留参数仍安装了 build'

# 没有任何 build 时仍生成空配置。
empty_root="${WORK_DIR}/empty-compilers"
empty_ce_home="${WORK_DIR}/empty-ce"
mkdir -p "${empty_root}" "${empty_ce_home}/etc/config"
bash "${REPO_ROOT}/vm/sync-ce-config.sh" \
  "${empty_ce_home}" "${REPO_ROOT}" "${empty_root}" >/dev/null
assert_contains 'compilers=' "${empty_ce_home}/etc/config/p4.local.properties"
grep -q '^group\.p4c\.compilers=' "${empty_ce_home}/etc/config/p4.local.properties" \
  && fail '没有 P4 build 时仍生成了编译器组'

echo 'PASS: P4 dated retention and generated compiler configs'
