#!/usr/bin/env bash
# 幂等更新 x86_64/riscv64 GCC，并原子切换对应的 *-latest 软链。
# 用法：update-gcc.sh [x86_64|riscv64|all]（默认 all）
set -euo pipefail

[[ "$#" -le 1 ]] || { echo "用法: $0 [x86_64|riscv64|all]" >&2; exit 2; }

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
prepare_toolchain_update

GCC_TARBALL_URL="${GCC_TARBALL_URL:-}"
GCC_RISCV_TARBALL_URL="${GCC_RISCV_TARBALL_URL:-}"
GCC_SHA256="$(normalize_sha256 GCC_SHA256 "${GCC_SHA256:-}")"
GCC_RISCV_SHA256="$(normalize_sha256 GCC_RISCV_SHA256 "${GCC_RISCV_SHA256:-}")"
PREPKG_BASE="https://github.com/prepkg/gcc-toolchain/releases/latest/download"

gcc_version_id() {
  local triple="$1" headers modified
  headers="$(curl -fsSIL --retry 3 "${PREPKG_BASE}/gcc-${triple}.tar.gz")"
  modified="$(printf '%s\n' "${headers}" | grep -i '^last-modified:' | tail -1 | sed -E 's/^[^:]*: *//; s/\r//g')"
  [[ -n "${modified}" ]] \
    || { echo "错误: 取不到 gcc-${triple} 的 Last-Modified。" >&2; return 1; }
  date -d "${modified}" +%Y%m%d-%H%M%S 2>/dev/null || echo "${modified//[^0-9]/}"
}

update_gcc() { # update_gcc <triple> <link-name> <url-override> <sha256>
  local triple="$1" link="$2" override="$3" checksum="$4" url verid gcc_version
  if [[ -n "${override}" ]]; then
    url="${override}"
    verid="$(basename "${url}")"
    verid="${verid%.tar.gz}"
    verid="${verid%.tar.xz}"
  else
    url="${PREPKG_BASE}/gcc-${triple}.tar.gz"
    echo ">> 检查 gcc-${triple} 最新资产版本 ..."
    verid="$(gcc_version_id "${triple}")"
  fi
  install_versioned_toolchain \
    "${link}" "gcc-${triple}" "${verid}" "${url}" "bin/${triple}-g++" "${checksum}"

  gcc_version="$(detect_semver \
    "${CE_COMPILERS_ROOT}/${link}/bin/${triple}-g++" -dumpfullversion -dumpversion)"
  case "${triple}" in
    x86_64-linux-gnu)
      sync_config_property c.local.properties compiler.gcc.semver "${gcc_version}"
      sync_config_property c++.local.properties compiler.g++.semver "${gcc_version}"
      ;;
    riscv64-linux-gnu)
      sync_config_property c.local.properties compiler.riscv64-gcc.semver "${gcc_version}"
      sync_config_property c++.local.properties compiler.riscv64-g++.semver "${gcc_version}"
      ;;
    *) echo "错误: 不支持同步配置的 GCC target: ${triple}" >&2; return 1 ;;
  esac
}

case "${1:-all}" in
  x86_64|x86) update_gcc x86_64-linux-gnu gcc-latest "${GCC_TARBALL_URL}" "${GCC_SHA256}" ;;
  riscv64|riscv) update_gcc riscv64-linux-gnu gcc-riscv-latest "${GCC_RISCV_TARBALL_URL}" "${GCC_RISCV_SHA256}" ;;
  all)
    update_gcc x86_64-linux-gnu gcc-latest "${GCC_TARBALL_URL}" "${GCC_SHA256}"
    update_gcc riscv64-linux-gnu gcc-riscv-latest "${GCC_RISCV_TARBALL_URL}" "${GCC_RISCV_SHA256}"
    ;;
  *) echo "用法: $0 [x86_64|riscv64|all]" >&2; exit 2 ;;
esac

finish_toolchain_update "GCC"
