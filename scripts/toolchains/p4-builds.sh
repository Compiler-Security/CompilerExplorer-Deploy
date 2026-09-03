#!/usr/bin/env bash
# P4 build 元数据解析与保留选择；供部署清理和 CE 配置生成共同使用。

P4_RETENTION_POLICY_FILE=".p4-retention-days"
P4_BUILD_REQUIRED_EXES=(
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
P4_BUILD_REQUIRED_FILES=(share/p4c/p4include/core.p4)

P4_RETENTION_DAYS=7
P4_SELECTED_BUILD_IDS=()
P4_SELECTED_BUILD_KINDS=()
P4_SELECTED_BUILD_LABELS=()
P4_SELECTED_BUILD_PATHS=()
P4_ALL_BUILD_PATHS=()
P4_REJECTED_BUILD_PATHS=()
P4_LATEST_BUILD_PATH=""

p4_load_retention_days() { # <compiler-root>
  local compiler_root="$1" raw_value="${P4_TOOLCHAIN_RETENTION_DAYS:-}"
  local policy_file="${compiler_root}/${P4_RETENTION_POLICY_FILE}"

  if [[ -z "${raw_value}" && -f "${policy_file}" ]]; then
    IFS= read -r raw_value < "${policy_file}" || true
  fi
  raw_value="${raw_value:-7}"
  [[ "${raw_value}" =~ ^[0-9]+$ ]] \
    || { echo "错误: P4_TOOLCHAIN_RETENTION_DAYS 必须是非负整数: ${raw_value}" >&2; return 2; }
  P4_RETENTION_DAYS=$((10#${raw_value}))
}

p4_build_is_complete() { # <build-root>
  local build_root="$1" relative
  [[ -d "${build_root}" ]] || return 1
  for relative in "${P4_BUILD_REQUIRED_EXES[@]}"; do
    [[ -x "${build_root}/${relative}" ]] || return 1
  done
  for relative in "${P4_BUILD_REQUIRED_FILES[@]}"; do
    [[ -f "${build_root}/${relative}" ]] || return 1
  done
}

p4_parse_build_id() { # <build-id>; writes P4_PARSED_*
  local build_id="$1" timestamp parsed_build_number formatted normalized
  P4_PARSED_KIND=unknown
  P4_PARSED_DATE=""
  P4_PARSED_TIMESTAMP=""
  P4_PARSED_BUILD_NUMBER="0"
  P4_PARSED_LABEL="${build_id}"

  if [[ "${build_id}" =~ ^([0-9]{12})-([0-9]+)-([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    timestamp="${BASH_REMATCH[1]}"
    parsed_build_number="${BASH_REMATCH[2]}"
    formatted="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:8:2}:${timestamp:10:2}"
    normalized="$(TZ=UTC date -d "${formatted}" +%Y%m%d%H%M 2>/dev/null || true)"
    if [[ "${normalized}" == "${timestamp}" ]]; then
      P4_PARSED_KIND=dated
      P4_PARSED_DATE="${timestamp:0:8}"
      P4_PARSED_TIMESTAMP="${timestamp}"
      P4_PARSED_BUILD_NUMBER="${parsed_build_number}"
      P4_PARSED_LABEL="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}"
    fi
    return 0
  fi

  if [[ "${build_id}" =~ ^([0-9]+)-([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    P4_PARSED_KIND=legacy
    P4_PARSED_BUILD_NUMBER="${BASH_REMATCH[1]}"
    P4_PARSED_LABEL="${BASH_REMATCH[1]}"
  fi
}

p4_array_contains() { # <needle> [items...]
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

p4_select_builds() { # <compiler-root>; uses P4_RETENTION_DAYS and writes P4_* arrays
  local compiler_root="$1" candidate build_id mtime record
  local latest_date="" cutoff_date="" previous_date="" date_value label build_path kind_rank
  local _timestamp _number _id _label _path _rank _mtime _kind
  local dated_count=0 remaining=0 index
  local -a dated_records=() legacy_records=() sorted_dated=() sorted_legacy=()

  P4_SELECTED_BUILD_IDS=()
  P4_SELECTED_BUILD_KINDS=()
  P4_SELECTED_BUILD_LABELS=()
  P4_SELECTED_BUILD_PATHS=()
  P4_ALL_BUILD_PATHS=()
  P4_REJECTED_BUILD_PATHS=()
  P4_LATEST_BUILD_PATH=""

  shopt -s nullglob
  for candidate in "${compiler_root}"/p4mlir-*; do
    [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
    P4_ALL_BUILD_PATHS+=("${candidate}")
    p4_build_is_complete "${candidate}" || continue

    build_id="${candidate##*/p4mlir-}"
    mtime="$(find "${candidate}" -maxdepth 0 -printf '%T@')"
    p4_parse_build_id "${build_id}"
    if [[ "${P4_PARSED_KIND}" == dated ]]; then
      dated_records+=(
        "${P4_PARSED_DATE}"$'\t'"${P4_PARSED_TIMESTAMP}"$'\t'"${P4_PARSED_BUILD_NUMBER}"$'\t'"${build_id}"$'\t'"${P4_PARSED_LABEL}"$'\t'"${candidate}"
      )
    else
      kind_rank=1
      [[ "${P4_PARSED_KIND}" == legacy ]] && kind_rank=0
      legacy_records+=(
        "${kind_rank}"$'\t'"${P4_PARSED_BUILD_NUMBER}"$'\t'"${mtime}"$'\t'"${build_id}"$'\t'"${P4_PARSED_KIND}"$'\t'"${P4_PARSED_LABEL}"$'\t'"${candidate}"
      )
    fi
  done
  shopt -u nullglob

  if ((${#dated_records[@]} > 0)); then
    mapfile -t sorted_dated < <(
      printf '%s\n' "${dated_records[@]}" \
        | sort -t $'\t' -k1,1r -k2,2r -k3,3nr -k4,4r
    )
    IFS=$'\t' read -r latest_date _timestamp _number _id _label _path <<< "${sorted_dated[0]}"
    if ((P4_RETENTION_DAYS > 0)); then
      cutoff_date="$(
        TZ=UTC date -d \
          "${latest_date:0:4}-${latest_date:4:2}-${latest_date:6:2} -$((P4_RETENTION_DAYS - 1)) days" \
          +%Y%m%d
      )"
    fi

    previous_date=""
    for record in "${sorted_dated[@]}"; do
      IFS=$'\t' read -r date_value _timestamp _number build_id label build_path <<< "${record}"
      [[ "${date_value}" == "${previous_date}" ]] && continue
      previous_date="${date_value}"
      if [[ -n "${cutoff_date}" && "${date_value}" < "${cutoff_date}" ]]; then
        continue
      fi
      P4_SELECTED_BUILD_IDS+=("${build_id}")
      P4_SELECTED_BUILD_KINDS+=(dated)
      P4_SELECTED_BUILD_LABELS+=("${label}")
      P4_SELECTED_BUILD_PATHS+=("${build_path}")
      dated_count=$((dated_count + 1))
    done
  fi

  if ((${#legacy_records[@]} > 0)); then
    mapfile -t sorted_legacy < <(
      printf '%s\n' "${legacy_records[@]}" \
        | sort -t $'\t' -k1,1n -k2,2nr -k3,3nr -k4,4r
    )
    if ((P4_RETENTION_DAYS == 0)); then
      remaining="${#sorted_legacy[@]}"
    else
      remaining=$((P4_RETENTION_DAYS - dated_count))
      ((remaining >= 0)) || remaining=0
    fi

    for ((index = 0; index < ${#sorted_legacy[@]} && index < remaining; index++)); do
      record="${sorted_legacy[index]}"
      IFS=$'\t' read -r _rank _number _mtime build_id _kind label build_path <<< "${record}"
      P4_SELECTED_BUILD_IDS+=("${build_id}")
      P4_SELECTED_BUILD_KINDS+=("${_kind}")
      P4_SELECTED_BUILD_LABELS+=("${label}")
      P4_SELECTED_BUILD_PATHS+=("${build_path}")
    done
  fi

  P4_LATEST_BUILD_PATH="${P4_SELECTED_BUILD_PATHS[0]:-}"
  for candidate in "${P4_ALL_BUILD_PATHS[@]}"; do
    if ! p4_array_contains "${candidate}" "${P4_SELECTED_BUILD_PATHS[@]}"; then
      P4_REJECTED_BUILD_PATHS+=("${candidate}")
    fi
  done
}
