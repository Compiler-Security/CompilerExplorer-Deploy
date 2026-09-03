#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

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

make_archive() {
  local build_id="$1" stage archive
  local executable
  stage="${WORK_DIR}/stage-${build_id}"
  archive="${WORK_DIR}/p4mlir-${build_id}.tar.gz"
  mkdir -p "${stage}/bin" "${stage}/share/p4c/p4include"
  for executable in \
    p4c p4mlir-opt p4mlir-translate p4mlir-to-json mlir-translate \
    opt llc llvm-objdump llvm-cxxfilt; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stage}/bin/${executable}"
    chmod +x "${stage}/bin/${executable}"
  done
  printf '// test core.p4\n' > "${stage}/share/p4c/p4include/core.p4"
  tar -czf "${archive}" -C "${stage}" .
  printf '%s' "${archive}"
}

deploy() {
  local root="$1" build_id="$2" max_builds="${3:-default}" archive
  archive="$(make_archive "${build_id}")"
  if [[ "${max_builds}" == default ]]; then
    CE_COMPILERS_ROOT="${root}" \
      bash "${REPO_ROOT}/scripts/toolchains/deploy-p4.sh" "${archive}" >/dev/null
  else
    CE_COMPILERS_ROOT="${root}" P4_TOOLCHAIN_MAX_BUILDS="${max_builds}" \
      bash "${REPO_ROOT}/scripts/toolchains/deploy-p4.sh" "${archive}" >/dev/null
  fi
}

count_builds() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -name 'p4mlir-*' | wc -l | tr -d '[:space:]'
}

compiler_root="${WORK_DIR}/compilers"
mkdir -p "${compiler_root}"

deploy "${compiler_root}" 101-a1a1a1a1
deploy "${compiler_root}" 102-b2b2b2b2
deploy "${compiler_root}" 103-c3c3c3c3
deploy "${compiler_root}" 104-d4d4d4d4
deploy "${compiler_root}" 105-e5e5e5e5
assert_eq 4 "$(count_builds "${compiler_root}")" '默认保留数量'
[[ ! -e "${compiler_root}/p4mlir-101-a1a1a1a1" ]] || fail '默认清理未删除最旧 build'

deploy "${compiler_root}" 106-f6f6f6f6 2
assert_eq 2 "$(count_builds "${compiler_root}")" '自定义保留数量'
[[ -d "${compiler_root}/p4mlir-106-f6f6f6f6" ]] || fail '当前 build 被错误清理'

deploy "${compiler_root}" 107-a7a7a7a7 0
deploy "${compiler_root}" 108-b8b8b8b8 0
assert_eq 4 "$(count_builds "${compiler_root}")" '0 应禁用自动清理'
assert_eq p4mlir-108-b8b8b8b8 "$(readlink "${compiler_root}/p4-latest")" 'latest 软链'

invalid_archive="$(make_archive 109-c9c9c9c9)"
if CE_COMPILERS_ROOT="${compiler_root}" P4_TOOLCHAIN_MAX_BUILDS=invalid \
  bash "${REPO_ROOT}/scripts/toolchains/deploy-p4.sh" "${invalid_archive}" >/dev/null 2>&1; then
  fail '非法 P4_TOOLCHAIN_MAX_BUILDS 未被拒绝'
fi
[[ ! -e "${compiler_root}/p4mlir-109-c9c9c9c9" ]] || fail '非法保留参数仍安装了 build'

# 不完整目录必须被跳过，不能污染任何编译器菜单。
mkdir -p "${compiler_root}/p4mlir-999-deadbeef/bin"

ce_home="${WORK_DIR}/ce"
mkdir -p "${ce_home}/etc/config"
sync_log="${WORK_DIR}/sync.log"
bash "${REPO_ROOT}/vm/sync-ce-config.sh" \
  "${ce_home}" "${REPO_ROOT}" "${compiler_root}" >"${sync_log}" 2>&1

p4_config="${ce_home}/etc/config/p4.local.properties"
[[ -f "${p4_config}" && ! -L "${p4_config}" ]] || fail 'P4 配置没有生成为普通文件'
assert_contains 'compilers=&p4c:&p4mlirtranslate' "${p4_config}"
assert_contains 'defaultCompiler=p4c' "${p4_config}"
assert_contains 'group.p4mlirtranslate.isSemVer=true' "${p4_config}"
assert_contains 'tools.p4pipe-opt.exclude=p4c' "${p4_config}"
assert_contains "tools.p4pipe-opt.exe=${compiler_root}/p4-latest/bin/opt" "${p4_config}"
grep -Fq '跳过不完整的 P4 build' "${sync_log}" || fail '不完整 build 没有告警'
grep -Fq 'deadbeef' "${p4_config}" && fail '不完整 build 被注册'

actual_translate_names="$(
  sed -n 's/^compiler\..*\.name=\(p4mlir-translate (.*)\)$/\1/p' "${p4_config}"
)"
expected_translate_names="$(printf '%s\n' \
  'p4mlir-translate (latest)' \
  'p4mlir-translate (108)' \
  'p4mlir-translate (107)' \
  'p4mlir-translate (106)' \
  'p4mlir-translate (105)')"
assert_eq "${expected_translate_names}" "${actual_translate_names}" 'translate 菜单顺序'

grep -Fq "options=${compiler_root}/p4mlir-107-a7a7a7a7/share/p4c/p4include" "${p4_config}" \
  || fail '历史 translate 没有使用同 build include 路径'

for language in p4 mlir_p4 llvm_p4 llvm_mir_p4; do
  generated="${ce_home}/etc/config/${language}.local.properties"
  [[ -f "${generated}" && ! -L "${generated}" ]] || fail "${language} 配置未生成"
  grep -Fq '(latest)' "${generated}" || fail "${language} 缺少 latest 项"
  grep -Fq '(108)' "${generated}" || fail "${language} 缺少历史构建号项"
  grep -Fq 'semver=1.0.0' "${generated}" || fail "${language} 缺少 latest 排序元数据"
  grep -Fq '@' "${generated}" && fail "${language} 仍含未替换模板变量"
done

assert_contains 'compilers=&p4mliropt:&p4mlirtojson:&mlirtranslate' \
  "${ce_home}/etc/config/mlir_p4.local.properties"

empty_root="${WORK_DIR}/empty-compilers"
empty_ce_home="${WORK_DIR}/empty-ce"
mkdir -p "${empty_root}" "${empty_ce_home}/etc/config"
bash "${REPO_ROOT}/vm/sync-ce-config.sh" \
  "${empty_ce_home}" "${REPO_ROOT}" "${empty_root}" >/dev/null
assert_contains 'compilers=' "${empty_ce_home}/etc/config/p4.local.properties"
grep -q '^group\.p4c\.compilers=' "${empty_ce_home}/etc/config/p4.local.properties" \
  && fail '没有 P4 build 时仍生成了编译器组'

echo 'PASS: P4 toolchain retention and generated compiler configs'
