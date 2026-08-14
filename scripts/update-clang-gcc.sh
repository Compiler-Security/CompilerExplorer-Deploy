#!/usr/bin/env bash
# =============================================================================
# update-clang-gcc.sh —— 下载预编译 Clang/GCC 到宿主机工具链根，
#   并拨动 *-latest 符号链接 + 重启 CE。
#
#   用法:
#     update-clang-gcc.sh clang          # 最新 Clang/LLVM (x86 宿主, 全后端含 RISC-V)
#     update-clang-gcc.sh gcc            # 最新 GCC, x86_64 原生
#     update-clang-gcc.sh gcc-riscv      # 最新 GCC, riscv64 交叉
#     update-clang-gcc.sh all            # clang + 两种 gcc
#
# 幂等：重复调用时若远端资产未变化则不重新下载（只确认/修复符号链接）：
#   * Clang 以 release tag 作版本目录（clang-22.1.8），tag 不可变。
#   * GCC 用 HEAD 请求取资产 Last-Modified 作内容标识（不下载正文）。
#
# 来源（都可用环境变量覆盖成内部镜像）：
#   * Clang/LLVM：官方 llvm-project GitHub Release 的 Linux-X64 tarball，
#       默认启用全部后端（含 RISC-V），同一份 clang 加 --target 即可交叉。
#   * GCC：gcc.gnu.org 只发源码。默认用 prepkg/gcc-toolchain（GCC 最新,
#       glibc 2.17 基线 → 能在 Debian bookworm 容器里跑, 可重定位, 解压即用）。
#
# 注意 prepkg 是「交叉式」布局：二进制带三元组前缀（<dest>/bin/<triple>-g++）。
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}"
# 工具链根：环境变量优先；否则读仓库根 .env；再不行报错。
if [[ -z "${CE_COMPILERS_ROOT:-}" && -f "${REPO_ROOT}/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"; set +a
fi
: "${CE_COMPILERS_ROOT:?未设置 CE_COMPILERS_ROOT。请 cp .env.example .env 并填入实际路径，或用环境变量传入。}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${CE_COMPILERS_ROOT}"

# ---- 可配置来源（留空则用默认）-----------------------------------------------
CLANG_TARBALL_URL="${CLANG_TARBALL_URL:-}"                 # 默认: 自动取最新 LLVM release
GCC_TARBALL_URL="${GCC_TARBALL_URL:-}"                     # 默认: prepkg x86_64
GCC_RISCV_TARBALL_URL="${GCC_RISCV_TARBALL_URL:-}"         # 默认: prepkg riscv64
PREPKG_BASE="https://github.com/prepkg/gcc-toolchain/releases/latest/download"

DID_CHANGE=0   # 是否有实际下载/换链接；用于决定要不要重启 CE

restart_ce() {
  echo ">> 重启 CE"
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" restart ce
}

# 原子拨链接
point_link() { # point_link <link-name> <target-dir>
  local link="${CE_COMPILERS_ROOT}/$1" target="$2"
  ln -sfn "${target}" "${CE_COMPILERS_ROOT}/.$1.tmp"
  mv -T "${CE_COMPILERS_ROOT}/.$1.tmp" "${link}"
  echo ">> $1 -> ${target}"
}

install_tarball() { # install_tarball <url> <dest> ; 解压并 strip 顶层目录
  local url="$1" dest="$2"
  echo ">> 下载 ${url}"
  curl -fSL --retry 3 -o "${WORK}/pkg.tar" "${url}"
  rm -rf "${dest}.partial"
  mkdir -p "${dest}.partial"
  tar -xf "${WORK}/pkg.tar" -C "${dest}.partial" --strip-components=1
  mv -T "${dest}.partial" "${dest}"
  # SELinux (Enforcing) 下打容器可读标签，确保 CE 容器能读到新工具链。
  if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
    chcon -R -t container_file_t "${dest}" || true
  fi
}

# install_versioned <link> <dirbase> <version-id> <url> <exe-relpath>
# 幂等核心：目标目录 <dirbase>-<version-id> 已存在且二进制可用 → 不重新下载。
install_versioned() {
  local link="$1" dirbase="$2" verid="$3" url="$4" exe="$5"
  local dest="${CE_COMPILERS_ROOT}/${dirbase}-${verid}"

  if [[ -x "${dest}/${exe}" ]]; then
    if [[ "$(readlink -f "${CE_COMPILERS_ROOT}/${link}" 2>/dev/null || true)" == "$(readlink -f "${dest}")" ]]; then
      echo ">> [跳过] ${dirbase} 已是 ${verid}，${link} 已指向它 —— 不重复下载"
      return 0
    fi
    echo ">> [修复链接] ${dirbase} ${verid} 已存在，仅重拨 ${link}（不重新下载）"
    point_link "${link}" "${dest}"
    DID_CHANGE=1
    return 0
  fi

  echo ">> [更新] ${dirbase} -> ${verid}"
  install_tarball "${url}" "${dest}"
  [[ -x "${dest}/${exe}" ]] \
    || { echo "错误: ${dest}/${exe} 不存在，请检查 tarball 结构/来源"; exit 1; }
  point_link "${link}" "${dest}"
  DID_CHANGE=1
}

update_clang() {
  local url="${CLANG_TARBALL_URL}" verid=""
  if [[ -z "${url}" ]]; then
    echo ">> 查询最新 LLVM release ..."
    local json tag
    # 先完整取回响应再解析 —— 不要 curl 边下边接 grep -m1/head（提前关闭管道会让
    # curl 触发 SIGPIPE 报 (23)，在 pipefail 下直接中断脚本）。
    json="$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest)"
    tag="$(printf '%s\n' "${json}" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    tag="${tag%%$'\n'*}"
    [[ -n "${tag}" ]] || { echo "错误: 解析不到 LLVM 最新 tag（可能 API 限流/网络问题）；可手动设 CLANG_TARBALL_URL"; exit 1; }
    verid="${tag#llvmorg-}"
    # 从 release 资产里挑 Linux 预编译 tarball（资产名随版本会变，故不硬编码）。
    url="$(printf '%s\n' "${json}" \
           | grep -oE 'https://[^"]*(Linux-X64|clang\+llvm[^"]*[Ll]inux[^"]*(x86_64|X64))[^"]*\.tar\.xz' \
           || true)"
    url="${url%%$'\n'*}"
    [[ -n "${url}" ]] || { echo "错误: ${tag} 下找不到 Linux 预编译包；请手动设 CLANG_TARBALL_URL"; exit 1; }
    echo ">> 最新 LLVM: ${tag}"
  else
    # 自定义 URL：用文件名作版本标识（尽力而为）。
    verid="$(basename "${url}")"; verid="${verid%.tar.xz}"; verid="${verid%.tar.gz}"
  fi
  install_versioned clang-latest clang "${verid}" "${url}" "bin/clang++"
}

# gcc_version_id <triple> —— 用 HEAD 的 Last-Modified 作资产内容标识（不下载正文）。
gcc_version_id() {
  local triple="$1" hdrs lm
  hdrs="$(curl -fsSIL --retry 3 "${PREPKG_BASE}/gcc-${triple}.tar.gz")"
  lm="$(printf '%s\n' "${hdrs}" | grep -i '^last-modified:' | tail -1 | sed -E 's/^[^:]*: *//; s/\r//g')"
  [[ -n "${lm}" ]] || { echo "错误: 取不到 gcc-${triple} 的 Last-Modified"; return 1; }
  date -d "${lm}" +%Y%m%d-%H%M%S 2>/dev/null || echo "${lm//[^0-9]/}"
}

update_gcc() { # update_gcc <triple> <link-name> <url-override>
  local triple="$1" link="$2" override="${3:-}"
  local url verid
  if [[ -n "${override}" ]]; then
    url="${override}"
    verid="$(basename "${url}")"; verid="${verid%.tar.gz}"; verid="${verid%.tar.xz}"
  else
    url="${PREPKG_BASE}/gcc-${triple}.tar.gz"
    echo ">> 检查 gcc-${triple} 最新资产版本 ..."
    verid="$(gcc_version_id "${triple}")"
  fi
  install_versioned "${link}" "gcc-${triple}" "${verid}" "${url}" "bin/${triple}-g++"
}

case "${1:-all}" in
  clang)            update_clang ;;
  gcc)              update_gcc x86_64-linux-gnu gcc-latest "${GCC_TARBALL_URL}" ;;
  gcc-riscv|riscv)  update_gcc riscv64-linux-gnu gcc-riscv-latest "${GCC_RISCV_TARBALL_URL}" ;;
  all)
    update_clang
    update_gcc x86_64-linux-gnu gcc-latest "${GCC_TARBALL_URL}"
    update_gcc riscv64-linux-gnu gcc-riscv-latest "${GCC_RISCV_TARBALL_URL}"
    ;;
  *) echo "用法: $0 {clang|gcc|gcc-riscv|all}"; exit 2 ;;
esac

if [[ "${DID_CHANGE}" == "1" ]]; then
  restart_ce
else
  echo ">> 所有工具链均已是最新，无需重启 CE"
fi
echo ">> 完成。"
