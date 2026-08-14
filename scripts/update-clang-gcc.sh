#!/usr/bin/env bash
# =============================================================================
# update-clang-gcc.sh —— 下载官方预编译 Clang/GCC 到宿主机工具链根，
#   并拨动 *-latest 符号链接 + 重启 CE。
#
#   用法:
#     update-clang-gcc.sh clang          # 更新到最新 Clang/LLVM
#     update-clang-gcc.sh gcc            # 更新到最新 GCC
#     update-clang-gcc.sh all            # 两者
#
# 说明（来源按你的网络/发行版调整）：
#   * Clang/LLVM：官方 GitHub Release 提供 Linux-X64 预编译 tarball。
#   * GCC：gcc.gnu.org 不提供通用 x86_64 Linux 二进制 tarball。常见来源：
#       - 发行版包（Fedora: dnf；Ubuntu: apt/PPA）解包；
#       - Bootlin 预编译工具链；
#       - 你们内部镜像/制品库里的 GCC 包。
#     下面 GCC 段用「配置 URL 模板」的方式实现，默认留空由你填内部可用地址。
# =============================================================================
set -euo pipefail

CE_COMPIERS_ROOT="${CE_COMPILERS_ROOT:-/srv/ce/compilers}"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${CE_COMPIERS_ROOT}"

# ---- 可配置来源 -------------------------------------------------------------
# Clang: 留空则自动取最新 LLVM release 的 Linux-X64 资产。
CLANG_TARBALL_URL="${CLANG_TARBALL_URL:-}"
# GCC: 填入你内部/镜像可用的 GCC 预编译 tarball 地址（含版本）。
GCC_TARBALL_URL="${GCC_TARBALL_URL:-}"

restart_ce() {
  echo ">> 重启 CE"
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" restart ce
}

# 原子拨链接
point_link() { # point_link <link-name> <target-dir>
  local link="${CE_COMPIERS_ROOT}/$1" target="$2"
  ln -sfn "${target}" "${CE_COMPIERS_ROOT}/.$1.tmp"
  mv -T "${CE_COMPIERS_ROOT}/.$1.tmp" "${link}"
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
    local tag
    tag="$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest \
            | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    echo ">> 最新 LLVM tag: ${tag}"
    # LLVM release 资产命名形如: LLVM-<ver>-Linux-X64.tar.xz （按实际资产名调整）
    local ver="${tag#llvmorg-}"
    url="https://github.com/llvm/llvm-project/releases/download/${tag}/LLVM-${ver}-Linux-X64.tar.xz"
  fi
  local dest="${CE_COMPIERS_ROOT}/clang-$(date +%Y%m%d)"
  install_tarball "${url}" "${dest}"
  [[ -x "${dest}/bin/clang++" ]] || { echo "错误: ${dest}/bin/clang++ 不存在，请检查 tarball 结构/来源"; exit 1; }
  point_link clang-latest "${dest}"
}

update_gcc() {
  local url="${GCC_TARBALL_URL}"
  if [[ -z "${url}" ]]; then
    cat >&2 <<'EOF'
错误: 未设置 GCC_TARBALL_URL。
gcc.gnu.org 不提供通用 Linux 二进制 tarball。请设置 GCC_TARBALL_URL 指向你可用的
GCC 预编译包（发行版包解包 / Bootlin 工具链 / 内部制品库），例如：
  GCC_TARBALL_URL="https://your-mirror/gcc-15.2.0-x86_64.tar.xz" ./update-clang-gcc.sh gcc
EOF
    exit 1
  fi
  local dest="${CE_COMPIERS_ROOT}/gcc-$(date +%Y%m%d)"
  install_tarball "${url}" "${dest}"
  [[ -x "${dest}/bin/g++" ]] || { echo "错误: ${dest}/bin/g++ 不存在，请检查 tarball 结构/来源"; exit 1; }
  point_link gcc-latest "${dest}"
}

case "${1:-all}" in
  clang) update_clang; restart_ce ;;
  gcc)   update_gcc;   restart_ce ;;
  all)   update_clang; update_gcc; restart_ce ;;
  *) echo "用法: $0 {clang|gcc|all}"; exit 2 ;;
esac

echo ">> 完成。"
