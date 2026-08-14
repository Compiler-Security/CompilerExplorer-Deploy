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
# 来源（都可用环境变量覆盖成你们的内部镜像）：
#   * Clang/LLVM：官方 llvm-project GitHub Release 的 Linux-X64 tarball。
#       —— 它默认启用全部后端（含 RISC-V），同一份 clang 加 --target 即可交叉。
#   * GCC：gcc.gnu.org 只发源码。默认用 prepkg/gcc-toolchain（GCC 最新,
#       glibc 2.17 基线 → 能在 Debian bookworm 容器里跑, 可重定位, 解压即用），
#       覆盖 x86_64 / riscv64 等目标。备选 Bootlin（版本较旧）。
#
# 注意 prepkg/Bootlin 是「交叉式」布局：二进制带三元组前缀，
#   即 <triple>/bin/<triple>-g++（解压并 strip 顶层后为 <dest>/bin/<triple>-g++），
#   CE 配置里的 exe 要指向带前缀的那个（见 config/c++.local.properties）。
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

# ---- 可配置来源（留空则用下面的默认）-----------------------------------------
CLANG_TARBALL_URL="${CLANG_TARBALL_URL:-}"                 # 默认: 自动取最新 LLVM release
GCC_TARBALL_URL="${GCC_TARBALL_URL:-}"                     # 默认: prepkg x86_64
GCC_RISCV_TARBALL_URL="${GCC_RISCV_TARBALL_URL:-}"         # 默认: prepkg riscv64
PREPKG_BASE="https://github.com/prepkg/gcc-toolchain/releases/latest/download"

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

install_tarball() { # install_tarball <url> <dest-prefix> ; 解压并 strip 顶层目录
  local url="$1" dest="$2"
  echo ">> 下载 ${url}"
  curl -fSL --retry 3 -o "${WORK}/pkg.tar" "${url}"
  rm -rf "${dest}.partial"
  mkdir -p "${dest}.partial"
  # 自动识别 xz/gz；剥离 tarball 顶层单一目录，使 ${dest}/bin/... 直接可用。
  tar -xf "${WORK}/pkg.tar" -C "${dest}.partial" --strip-components=1
  mv -T "${dest}.partial" "${dest}"
  # SELinux (Enforcing) 下打容器可读标签，确保 CE 容器能读到新工具链。
  if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
    chcon -R -t container_file_t "${dest}" || true
  fi
}

update_clang() {
  local url="${CLANG_TARBALL_URL}"
  if [[ -z "${url}" ]]; then
    echo ">> 查询最新 LLVM release ..."
    local json tag
    # 先完整取回响应再解析 —— 不要 curl 边下边接 grep -m1/head（提前关闭管道会让
    # curl 触发 SIGPIPE 报 (23)，在 pipefail 下直接中断脚本）。
    json="$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest)"
    tag="$(printf '%s\n' "${json}" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    tag="${tag%%$'\n'*}"   # 取第一行
    [[ -n "${tag}" ]] || { echo "错误: 解析不到 LLVM 最新 tag（可能 API 限流/网络问题）；可手动设 CLANG_TARBALL_URL"; exit 1; }
    echo ">> 最新 LLVM tag: ${tag}"
    # 从 release 资产里挑 Linux 预编译 tarball（资产名随版本会变，故不硬编码）。
    url="$(printf '%s\n' "${json}" \
           | grep -oE 'https://[^"]*(Linux-X64|clang\+llvm[^"]*[Ll]inux[^"]*(x86_64|X64))[^"]*\.tar\.xz' \
           || true)"
    url="${url%%$'\n'*}"   # 取第一条
    [[ -n "${url}" ]] || { echo "错误: ${tag} 下找不到 Linux 预编译包；请手动设 CLANG_TARBALL_URL"; exit 1; }
    echo ">> 选用资产: ${url}"
  fi
  local dest="${CE_COMPILERS_ROOT}/clang-$(date +%Y%m%d)"
  install_tarball "${url}" "${dest}"
  [[ -x "${dest}/bin/clang++" ]] || { echo "错误: ${dest}/bin/clang++ 不存在，请检查 tarball 结构/来源"; exit 1; }
  point_link clang-latest "${dest}"
}

# update_gcc <triple> <link-name> <url-override>
#   默认从 prepkg 下载 gcc-<triple>.tar.gz；解压后为 <dest>/bin/<triple>-g++。
update_gcc() {
  local triple="$1" link="$2" override="${3:-}"
  local url="${override:-${PREPKG_BASE}/gcc-${triple}.tar.gz}"
  echo ">> GCC [${triple}] 来源: ${url}"
  local dest="${CE_COMPILERS_ROOT}/gcc-${triple}-$(date +%Y%m%d)"
  install_tarball "${url}" "${dest}"
  [[ -x "${dest}/bin/${triple}-g++" ]] \
    || { echo "错误: ${dest}/bin/${triple}-g++ 不存在，请检查 tarball 结构/来源"; exit 1; }
  point_link "${link}" "${dest}"
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
restart_ce
echo ">> 完成。"
