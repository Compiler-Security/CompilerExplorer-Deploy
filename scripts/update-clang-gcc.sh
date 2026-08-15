#!/usr/bin/env bash
# 幂等更新预编译 Clang/GCC 并原子切换 *-latest 软链。
# 用法：update-clang-gcc.sh {clang|gcc|gcc-riscv|all}
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${CE_COMPILERS_ROOT:-}" && -f "${REPO_ROOT}/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"; set +a
fi
: "${CE_COMPILERS_ROOT:?未设置 CE_COMPILERS_ROOT。请 cp .env.example .env 并填入实际路径，或用环境变量传入。}"

CE_COMPILERS_ROOT="$(readlink -m "${CE_COMPILERS_ROOT}")"
if [[ -z "${CE_COMPILERS_ROOT}" || "${CE_COMPILERS_ROOT}" == "/" ]]; then
  echo "错误: CE_COMPILERS_ROOT 为空或为根目录，已拒绝（防止 rm -rf 误删）。" >&2
  exit 1
fi

WORK="$(mktemp -d)"
PARTIAL=""
cleanup() {
  [[ -z "${PARTIAL}" ]] || rm -rf -- "${PARTIAL}"
  rm -rf -- "${WORK}"
}
trap cleanup EXIT

mkdir -p "${CE_COMPILERS_ROOT}"
command -v flock >/dev/null 2>&1 \
  || { echo "错误: 缺少 flock（通常由 util-linux 提供），无法安全串行更新工具链。" >&2; exit 1; }
exec 9>"${CE_COMPILERS_ROOT}/.update.lock"
flock 9

CLANG_TARBALL_URL="${CLANG_TARBALL_URL:-}"
GCC_TARBALL_URL="${GCC_TARBALL_URL:-}"
GCC_RISCV_TARBALL_URL="${GCC_RISCV_TARBALL_URL:-}"
PREPKG_BASE="https://github.com/prepkg/gcc-toolchain/releases/latest/download"

LLVM_SHA256="${LLVM_SHA256:-}"
GCC_SHA256="${GCC_SHA256:-}"
GCC_RISCV_SHA256="${GCC_RISCV_SHA256:-}"
for checksum in "${LLVM_SHA256}" "${GCC_SHA256}" "${GCC_RISCV_SHA256}"; do
  [[ -z "${checksum}" || "${checksum}" =~ ^[[:xdigit:]]{64}$ ]] \
    || { echo "错误: 工具链 SHA256 必须是 64 位十六进制。" >&2; exit 2; }
done
LLVM_SHA256="${LLVM_SHA256,,}"
GCC_SHA256="${GCC_SHA256,,}"
GCC_RISCV_SHA256="${GCC_RISCV_SHA256,,}"

DID_CHANGE=0

# shellcheck source=lib-vm.sh
source "${REPO_ROOT}/scripts/lib-vm.sh"

point_link() { # point_link <link-name> <target-dir>
  local name="$1" link="${CE_COMPILERS_ROOT}/$1" target="$2" target_name tmp
  target_name="$(basename "${target}")"
  [[ "$(dirname "${target}")" == "${CE_COMPILERS_ROOT}" ]] \
    || { echo "错误: 软链目标不在 CE_COMPILERS_ROOT 内: ${target}" >&2; exit 1; }
  tmp="${CE_COMPILERS_ROOT}/.${name}.tmp.$$"
  ln -s "${target_name}" "${tmp}"
  mv -Tf "${tmp}" "${link}"
  echo ">> ${name} -> ${target_name}"
}

# 下载、校验并去掉 tarball 顶层目录。
install_tarball() {
  local url="$1" dest="$2" expect_sha="${3:-}" sig_url="${4:-}"
  echo ">> 下载 ${url}"
  curl -fSL --retry 3 -o "${WORK}/pkg.tar" "${url}"

  local actual_sha
  actual_sha="$(sha256sum "${WORK}/pkg.tar" | awk '{print $1}')"
  if [[ -n "${expect_sha}" ]]; then
    if [[ "${actual_sha}" != "${expect_sha}" ]]; then
      echo "错误: SHA256 不匹配！已中止，未解压。" >&2
      echo "  期望: ${expect_sha}" >&2
      echo "  实际: ${actual_sha}" >&2
      echo "  （若是官方发布了新版，请核对后更新 .env 里钉的哈希）" >&2
      exit 1
    fi
    echo ">> SHA256 校验通过: ${actual_sha}"
  else
    echo ">> 未固定 SHA256。本次下载哈希: ${actual_sha}"
    echo ">>   （可把它写进 .env 对应变量钉死，之后每次下载都会强制比对）"
    # 未固定哈希时，LLVM 包尽量再验证发布签名。
    if [[ -n "${sig_url}" ]]; then
      if command -v gpg >/dev/null 2>&1; then
        if curl -fsSL -o "${WORK}/pkg.sig" "${sig_url}" \
           && gpg --verify "${WORK}/pkg.sig" "${WORK}/pkg.tar" 2>/dev/null; then
          echo ">> GPG 签名验证通过"
        else
          echo ">> 警告: GPG 签名未能验证（多半是没导入 LLVM 发布密钥）。要强校验请固定 SHA256。" >&2
        fi
      else
        echo ">> 提示: 本机无 gpg，跳过 LLVM 签名验证；建议固定 SHA256。" >&2
      fi
    fi
  fi

  PARTIAL="${CE_COMPILERS_ROOT}/.$(basename "${dest}").partial.$$"
  rm -rf -- "${PARTIAL}"
  mkdir -p "${PARTIAL}"
  tar -xf "${WORK}/pkg.tar" -C "${PARTIAL}" --strip-components=1
  # 目标名由脚本生成且限定在工具链根的直接子目录。
  [[ ! -e "${dest}" ]] || rm -rf -- "${dest}"
  mv -T "${PARTIAL}" "${dest}"
  PARTIAL=""
  if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
    chcon -R -t container_file_t "${dest}" || true
  fi
}

# 已安装且二进制可用时只检查/修复软链。
install_versioned() {
  local link="$1" dirbase="$2" verid="$3" url="$4" exe="$5" expect_sha="${6:-}" sig_url="${7:-}"
  verid="${verid//[^A-Za-z0-9._-]/_}"
  [[ -n "${verid}" ]] || { echo "错误: 无法从下载地址得到安全的版本标识" >&2; exit 1; }
  local dest="${CE_COMPILERS_ROOT}/${dirbase}-${verid}"

  if [[ -x "${dest}/${exe}" ]]; then
    if [[ "$(readlink "${CE_COMPILERS_ROOT}/${link}" 2>/dev/null || true)" == "$(basename "${dest}")" ]]; then
      echo ">> [跳过] ${dirbase} 已是 ${verid}，${link} 已指向它 —— 不重复下载"
      return 0
    fi
    echo ">> [修复链接] ${dirbase} ${verid} 已存在，仅重拨 ${link}（不重新下载）"
    point_link "${link}" "${dest}"
    DID_CHANGE=1
    return 0
  fi

  echo ">> [更新] ${dirbase} -> ${verid}"
  install_tarball "${url}" "${dest}" "${expect_sha}" "${sig_url}"
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
    # 先完整取回，避免 pipefail 下 curl 被下游提前关闭。
    json="$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest)"
    tag="$(printf '%s\n' "${json}" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    tag="${tag%%$'\n'*}"
    [[ -n "${tag}" ]] || { echo "错误: 解析不到 LLVM 最新 tag（可能 API 限流/网络问题）；可手动设 CLANG_TARBALL_URL"; exit 1; }
    verid="${tag#llvmorg-}"
    url="$(printf '%s\n' "${json}" \
           | grep -oE 'https://[^"]*(Linux-X64|clang\+llvm[^"]*[Ll]inux[^"]*(x86_64|X64))[^"]*\.tar\.xz' \
           || true)"
    url="${url%%$'\n'*}"
    [[ -n "${url}" ]] || { echo "错误: ${tag} 下找不到 Linux 预编译包；请手动设 CLANG_TARBALL_URL"; exit 1; }
    echo ">> 最新 LLVM: ${tag}"
  else
    verid="$(basename "${url}")"; verid="${verid%.tar.xz}"; verid="${verid%.tar.gz}"
  fi
  install_versioned clang-latest clang "${verid}" "${url}" "bin/clang++" "${LLVM_SHA256}" "${url}.sig"
}

# 用 HEAD 的 Last-Modified 标识 prepkg latest 资产。
gcc_version_id() {
  local triple="$1" hdrs lm
  hdrs="$(curl -fsSIL --retry 3 "${PREPKG_BASE}/gcc-${triple}.tar.gz")"
  lm="$(printf '%s\n' "${hdrs}" | grep -i '^last-modified:' | tail -1 | sed -E 's/^[^:]*: *//; s/\r//g')"
  [[ -n "${lm}" ]] || { echo "错误: 取不到 gcc-${triple} 的 Last-Modified"; return 1; }
  date -d "${lm}" +%Y%m%d-%H%M%S 2>/dev/null || echo "${lm//[^0-9]/}"
}

update_gcc() { # update_gcc <triple> <link-name> <url-override> <sha256-pin>
  local triple="$1" link="$2" override="${3:-}" pin="${4:-}"
  local url verid
  if [[ -n "${override}" ]]; then
    url="${override}"
    verid="$(basename "${url}")"; verid="${verid%.tar.gz}"; verid="${verid%.tar.xz}"
  else
    url="${PREPKG_BASE}/gcc-${triple}.tar.gz"
    echo ">> 检查 gcc-${triple} 最新资产版本 ..."
    verid="$(gcc_version_id "${triple}")"
  fi
  install_versioned "${link}" "gcc-${triple}" "${verid}" "${url}" "bin/${triple}-g++" "${pin}" ""
}

case "${1:-all}" in
  clang)            update_clang ;;
  gcc)              update_gcc x86_64-linux-gnu gcc-latest "${GCC_TARBALL_URL}" "${GCC_SHA256}" ;;
  gcc-riscv|riscv)  update_gcc riscv64-linux-gnu gcc-riscv-latest "${GCC_RISCV_TARBALL_URL}" "${GCC_RISCV_SHA256}" ;;
  all)
    update_clang
    update_gcc x86_64-linux-gnu gcc-latest "${GCC_TARBALL_URL}" "${GCC_SHA256}"
    update_gcc riscv64-linux-gnu gcc-riscv-latest "${GCC_RISCV_TARBALL_URL}" "${GCC_RISCV_SHA256}"
    ;;
  *) echo "用法: $0 {clang|gcc|gcc-riscv|all}"; exit 2 ;;
esac

if [[ "${DID_CHANGE}" == "1" ]]; then
  if [[ "${CE_DEFER_RESTART:-0}" == "1" ]]; then
    if [[ -n "${CE_RESTART_NEEDED_FILE:-}" ]]; then
      : > "${CE_RESTART_NEEDED_FILE}"
    fi
    echo ">> CE 重启已交给统一工具链更新入口处理"
  else
    restart_ce_in_vm
  fi
else
  echo ">> 所有工具链均已是最新，无需重启 CE"
fi
echo ">> 完成。"
