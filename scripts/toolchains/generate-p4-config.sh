#!/usr/bin/env bash
# 从已安装的 P4 工具链生成 CE 配置；由 sync-ce-config.sh 在 CE 启动前调用。
set -euo pipefail

COMPILERS_ROOT="${1:-/opt/compiler-explorer}"
CONFIG_SRC="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config}"
CONFIG_DST="${3:-/opt/ce/etc/config}"

required_exes=(
  bin/p4c
  bin/p4mlir-opt
  bin/p4mlir-translate
  bin/p4mlir-to-json
  bin/mlir-translate
  bin/opt
  bin/llc
  bin/llvm-objdump
  bin/llvm-cxxfilt
)
required_files=(share/p4c/p4include/core.p4)
languages=(p4 mlir_p4 llvm_p4 llvm_mir_p4)

for language in "${languages[@]}"; do
  [[ -f "${CONFIG_SRC}/${language}.local.properties.template" ]] \
    || { echo "错误: 缺少 P4 配置模板 ${CONFIG_SRC}/${language}.local.properties.template" >&2; exit 1; }
done
[[ -d "${CONFIG_DST}" ]] \
  || { echo "错误: CE 配置目标目录不存在: ${CONFIG_DST}" >&2; exit 1; }
for required_command in awk find mktemp sha256sum sort; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || { echo "错误: 缺少命令 ${required_command}。" >&2; exit 1; }
done

build_is_complete() {
  local root="$1" relative
  [[ -d "${root}" ]] || return 1
  for relative in "${required_exes[@]}"; do
    [[ -x "${root}/${relative}" ]] || return 1
  done
  for relative in "${required_files[@]}"; do
    [[ -f "${root}/${relative}" ]] || return 1
  done
}

stable_token() {
  local checksum
  checksum="$(printf '%s' "$1" | sha256sum)"
  printf '%s' "${checksum:0:16}"
}

append_id() {
  local current="$1" id="$2"
  if [[ -n "${current}" ]]; then
    printf '%s:%s' "${current}" "${id}"
  else
    printf '%s' "${id}"
  fi
}

declare -a history_records=()
shopt -s nullglob
for candidate in "${COMPILERS_ROOT}"/p4mlir-*; do
  [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
  if ! build_is_complete "${candidate}"; then
    echo ">> 警告: 跳过不完整的 P4 build ${candidate}" >&2
    continue
  fi

  build_id="${candidate##*/p4mlir-}"
  mtime="$(find "${candidate}" -maxdepth 0 -printf '%T@')"
  if [[ "${build_id}" =~ ^([0-9]+)-([[:xdigit:]]{7,64})$ ]]; then
    # 标准 Jenkins build：标准项优先，按构建号降序；菜单只显示提交 hash。
    history_records+=("0"$'\t'"${BASH_REMATCH[1]}"$'\t'"${mtime}"$'\t'"${build_id}"$'\t'"${BASH_REMATCH[2]}"$'\t'"${candidate}")
  else
    # 旧格式没有可靠的构建号，保留完整 ID 并按部署时间降序。
    history_records+=("1"$'\t'"0"$'\t'"${mtime}"$'\t'"${build_id}"$'\t'"${build_id}"$'\t'"${candidate}")
  fi
done
shopt -u nullglob

declare -a history_labels=() history_paths=() history_tokens=()
if ((${#history_records[@]} > 0)); then
  mapfile -t sorted_records < <(
    printf '%s\n' "${history_records[@]}" \
      | sort -t $'\t' -k1,1n -k2,2nr -k3,3nr -k4,4r
  )
  for record in "${sorted_records[@]}"; do
    IFS=$'\t' read -r _kind _order _mtime build_id label build_path <<< "${record}"
    history_labels+=("${label}")
    history_paths+=("${build_path}")
    history_tokens+=("$(stable_token "${build_id}")")
  done
fi

latest_root="${COMPILERS_ROOT}/p4-latest"
latest_valid=0
if build_is_complete "${latest_root}"; then
  latest_valid=1
elif [[ -e "${latest_root}" || -L "${latest_root}" ]]; then
  echo ">> 警告: p4-latest 不完整或链接失效，不注册 latest 别名" >&2
fi

if ((latest_valid)); then
  toolchain_probe_root="${latest_root}"
elif ((${#history_paths[@]} > 0)); then
  toolchain_probe_root="${history_paths[0]}"
else
  toolchain_probe_root="${latest_root}"
fi

history_count="${#history_paths[@]}"
compiler_list() {
  local latest_id="$1" history_prefix="$2" result="" token
  if ((latest_valid)); then
    result="${latest_id}"
  fi
  for token in "${history_tokens[@]}"; do
    result="$(append_id "${result}" "${history_prefix}-history-${token}")"
  done
  printf '%s' "${result}"
}

emit_compiler_versions() { # <latest-id> <history-prefix> <executable> <display-base> [options-suffix]
  local latest_id="$1" history_prefix="$2" executable="$3" display_base="$4" options_suffix="${5:-}"
  local index id rank
  if ((latest_valid)); then
    printf '\ncompiler.%s.exe=%s/bin/%s\n' "${latest_id}" "${latest_root}" "${executable}"
    printf 'compiler.%s.name=%s (latest)\n' "${latest_id}" "${display_base}"
    printf 'compiler.%s.semver=1.0.0\n' "${latest_id}"
    if [[ -n "${options_suffix}" ]]; then
      printf 'compiler.%s.options=%s%s\n' "${latest_id}" "${latest_root}" "${options_suffix}"
    fi
  fi

  for index in "${!history_paths[@]}"; do
    id="${history_prefix}-history-${history_tokens[index]}"
    rank=$((history_count - index))
    printf '\ncompiler.%s.exe=%s/bin/%s\n' "${id}" "${history_paths[index]}" "${executable}"
    printf 'compiler.%s.name=%s (%s)\n' "${id}" "${display_base}" "${history_labels[index]}"
    printf 'compiler.%s.semver=0.%d.0\n' "${id}" "${rank}"
    if [[ -n "${options_suffix}" ]]; then
      printf 'compiler.%s.options=%s%s\n' "${id}" "${history_paths[index]}" "${options_suffix}"
    fi
  done
}

emit_p4_config() {
  local p4c_compilers translate_compilers
  p4c_compilers="$(compiler_list p4c p4c)"
  translate_compilers="$(compiler_list p4mlir-translate p4mlir-translate)"

  printf '\ngroup.p4c.compilers=%s\n' "${p4c_compilers}"
  printf 'group.p4c.baseName=p4c\n'
  printf 'group.p4c.isSemVer=true\n'
  printf 'group.p4mlirtranslate.compilers=%s\n' "${translate_compilers}"
  printf 'group.p4mlirtranslate.baseName=p4mlir-translate\n'
  printf 'group.p4mlirtranslate.isSemVer=true\n'
  emit_compiler_versions p4c p4c p4c p4c
  emit_compiler_versions \
    p4mlir-translate p4mlir-translate p4mlir-translate p4mlir-translate \
    '/share/p4c/p4include'
}

emit_mlir_p4_config() {
  local opt_compilers json_compilers translate_compilers
  opt_compilers="$(compiler_list p4mlir-opt p4mlir-opt)"
  json_compilers="$(compiler_list p4mlir-to-json p4mlir-to-json)"
  translate_compilers="$(compiler_list p4-mlir-translate p4-mlir-translate)"

  printf '\ngroup.p4mliropt.compilers=%s\n' "${opt_compilers}"
  printf 'group.p4mliropt.baseName=p4mlir-opt\n'
  printf 'group.p4mliropt.isSemVer=true\n'
  printf 'group.p4mlirtojson.compilers=%s\n' "${json_compilers}"
  printf 'group.p4mlirtojson.baseName=p4mlir-to-json\n'
  printf 'group.p4mlirtojson.isSemVer=true\n'
  # MLIR compilerType 通过 mlirtranslate 组名识别 translate 类工具。
  printf 'group.mlirtranslate.compilers=%s\n' "${translate_compilers}"
  printf 'group.mlirtranslate.baseName=mlir-translate P4 fork\n'
  printf 'group.mlirtranslate.isSemVer=true\n'
  emit_compiler_versions p4mlir-opt p4mlir-opt p4mlir-opt p4mlir-opt
  emit_compiler_versions p4mlir-to-json p4mlir-to-json p4mlir-to-json p4mlir-to-json
  emit_compiler_versions \
    p4-mlir-translate p4-mlir-translate mlir-translate 'mlir-translate P4 fork'
}

emit_llvm_p4_config() {
  local opt_compilers llc_compilers
  opt_compilers="$(compiler_list p4opt p4opt)"
  llc_compilers="$(compiler_list p4llc p4llc)"

  printf '\ngroup.p4opt.compilers=%s\n' "${opt_compilers}"
  printf 'group.p4opt.baseName=P4 opt\n'
  printf 'group.p4opt.isSemVer=true\n'
  printf 'group.p4opt.compilerType=opt\n'
  printf 'group.p4opt.supportsBinary=false\n'
  printf 'group.p4opt.instructionSet=llvm\n'
  printf 'group.p4opt.groupName=LLVM P4\n'
  printf 'group.p4opt.versionRe=LLVM version .*\n'
  printf 'group.p4llc.compilers=%s\n' "${llc_compilers}"
  printf 'group.p4llc.baseName=P4 llc\n'
  printf 'group.p4llc.isSemVer=true\n'
  printf 'group.p4llc.compilerType=llc\n'
  printf 'group.p4llc.groupName=LLVM P4\n'
  printf 'group.p4llc.versionRe=LLVM version .*\n'
  printf 'group.p4llc.intelAsm=--x86-asm-syntax=intel\n'
  emit_compiler_versions p4opt p4opt opt 'P4 opt'
  emit_compiler_versions p4llc p4llc llc 'P4 llc'
}

emit_llvm_mir_p4_config() {
  local llc_compilers
  llc_compilers="$(compiler_list p4-mir-llc p4-mir-llc)"

  printf '\ngroup.p4mirllc.compilers=%s\n' "${llc_compilers}"
  printf 'group.p4mirllc.baseName=P4 llc\n'
  printf 'group.p4mirllc.isSemVer=true\n'
  printf 'group.p4mirllc.compilerType=llc\n'
  printf 'group.p4mirllc.groupName=LLVM P4\n'
  printf 'group.p4mirllc.versionRe=LLVM version .*\n'
  emit_compiler_versions p4-mir-llc p4-mir-llc llc 'P4 llc'
}

render_template() { # <template> <compilers> <default-compiler>
  local template="$1" compilers="$2" default_compiler="$3"
  awk \
    -v compilers="${compilers}" \
    -v default_compiler="${default_compiler}" \
    -v toolchain_root="${toolchain_probe_root}" '
      function replace_all(text, token, value, position) {
        while ((position = index(text, token)) > 0) {
          text = substr(text, 1, position - 1) value substr(text, position + length(token))
        }
        return text
      }
      {
        line = replace_all($0, "@COMPILERS@", compilers)
        line = replace_all(line, "@DEFAULT_COMPILER@", default_compiler)
        line = replace_all(line, "@P4_TOOLCHAIN_ROOT@", toolchain_root)
        print line
      }
    ' "${template}"
}

generated_temp=""
cleanup() {
  [[ -z "${generated_temp}" ]] || rm -f -- "${generated_temp}"
}
trap cleanup EXIT

write_config() { # <language> <compilers> <default-compiler> <emit-function>
  local language="$1" compilers="$2" default_compiler="$3" emit_function="$4"
  local template="${CONFIG_SRC}/${language}.local.properties.template"
  local output="${CONFIG_DST}/${language}.local.properties"
  generated_temp="$(mktemp "${output}.tmp.XXXXXX")"
  chmod --reference="${template}" "${generated_temp}"
  render_template "${template}" "${compilers}" "${default_compiler}" > "${generated_temp}"
  if ((latest_valid || history_count > 0)); then
    "${emit_function}" >> "${generated_temp}"
  fi
  mv -Tf -- "${generated_temp}" "${output}"
  generated_temp=""
}

p4_default=""
mlir_p4_default=""
llvm_p4_default=""
llvm_mir_p4_default=""
if ((latest_valid)); then
  p4_default=p4c
  mlir_p4_default=p4mlir-opt
  llvm_p4_default=p4opt
  llvm_mir_p4_default=p4-mir-llc
elif ((${#history_tokens[@]} > 0)); then
  p4_default="p4c-history-${history_tokens[0]}"
  mlir_p4_default="p4mlir-opt-history-${history_tokens[0]}"
  llvm_p4_default="p4opt-history-${history_tokens[0]}"
  llvm_mir_p4_default="p4-mir-llc-history-${history_tokens[0]}"
fi

if ((latest_valid || history_count > 0)); then
  p4_compilers='&p4c:&p4mlirtranslate'
  mlir_p4_compilers='&p4mliropt:&p4mlirtojson:&mlirtranslate'
  llvm_p4_compilers='&p4opt:&p4llc'
  llvm_mir_p4_compilers='&p4mirllc'
else
  p4_compilers=''
  mlir_p4_compilers=''
  llvm_p4_compilers=''
  llvm_mir_p4_compilers=''
fi

write_config p4 "${p4_compilers}" "${p4_default}" emit_p4_config
write_config mlir_p4 "${mlir_p4_compilers}" "${mlir_p4_default}" emit_mlir_p4_config
write_config llvm_p4 "${llvm_p4_compilers}" "${llvm_p4_default}" emit_llvm_p4_config
write_config llvm_mir_p4 "${llvm_mir_p4_compilers}" "${llvm_mir_p4_default}" emit_llvm_mir_p4_config

echo ">> 已注册 ${history_count} 个 P4 build；latest=$([[ "${latest_valid}" == 1 ]] && echo yes || echo no)"
