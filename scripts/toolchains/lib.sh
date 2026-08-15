#!/usr/bin/env bash
# 工具链更新器共享：环境、串行锁、归档安装、软链切换和 CE 重启。

TOOLCHAINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLCHAINS_DIR}/../.." && pwd)"

if [[ -z "${CE_COMPILERS_ROOT:-}" && -f "${REPO_ROOT}/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"; set +a
fi
: "${CE_COMPILERS_ROOT:?未设置 CE_COMPILERS_ROOT。请 cp .env.example .env 并填入实际路径，或用环境变量传入。}"

CE_COMPILERS_ROOT="$(readlink -m "${CE_COMPILERS_ROOT}")"
if [[ -z "${CE_COMPILERS_ROOT}" || "${CE_COMPILERS_ROOT}" == "/" ]]; then
  echo "错误: CE_COMPILERS_ROOT 为空或为根目录，已拒绝（防止误删）。" >&2
  exit 1
fi

DID_CHANGE=0
TOOLCHAIN_WORK=""
TOOLCHAIN_PARTIAL=""

require_commands() {
  local name
  for name in "$@"; do
    command -v "${name}" >/dev/null 2>&1 \
      || { echo "错误: 缺少命令 ${name}。" >&2; exit 1; }
  done
}

lock_toolchains() {
  mkdir -p "${CE_COMPILERS_ROOT}"
  require_commands flock
  exec 9>"${CE_COMPILERS_ROOT}/.update.lock"
  flock 9
}

toolchain_cleanup() {
  [[ -z "${TOOLCHAIN_PARTIAL}" ]] || rm -rf -- "${TOOLCHAIN_PARTIAL}"
  [[ -z "${TOOLCHAIN_WORK}" ]] || rm -rf -- "${TOOLCHAIN_WORK}"
}

prepare_toolchain_update() {
  require_commands curl sha256sum tar
  lock_toolchains
  TOOLCHAIN_WORK="$(mktemp -d)"
  trap toolchain_cleanup EXIT
}

point_toolchain_link() { # point_toolchain_link <link-name> <target-dir>
  local name="$1" link="${CE_COMPILERS_ROOT}/$1" target="$2" target_name tmp
  target_name="$(basename "${target}")"
  [[ "$(dirname "${target}")" == "${CE_COMPILERS_ROOT}" ]] \
    || { echo "错误: 软链目标不在 CE_COMPILERS_ROOT 内: ${target}" >&2; exit 1; }
  tmp="${CE_COMPILERS_ROOT}/.${name}.tmp.$$"
  ln -s "${target_name}" "${tmp}"
  mv -Tf "${tmp}" "${link}"
  echo ">> ${name} -> ${target_name}"
}

install_toolchain_tarball() { # <url> <dest> <required-exe> [sha256] [signature-url]
  local url="$1" dest="$2" required_exe="$3" expect_sha="${4:-}" sig_url="${5:-}"
  local archive="${TOOLCHAIN_WORK}/pkg.tar" actual_sha

  echo ">> 下载 ${url}"
  curl -fSL --retry 3 -o "${archive}" "${url}"
  actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"

  if [[ -n "${expect_sha}" ]]; then
    if [[ "${actual_sha}" != "${expect_sha}" ]]; then
      echo "错误: SHA256 不匹配！已中止，未解压。" >&2
      echo "  期望: ${expect_sha}" >&2
      echo "  实际: ${actual_sha}" >&2
      exit 1
    fi
    echo ">> SHA256 校验通过: ${actual_sha}"
  else
    echo ">> 未固定 SHA256。本次下载哈希: ${actual_sha}"
    if [[ -n "${sig_url}" ]]; then
      if command -v gpg >/dev/null 2>&1; then
        if curl -fsSL -o "${TOOLCHAIN_WORK}/pkg.sig" "${sig_url}" \
           && gpg --verify "${TOOLCHAIN_WORK}/pkg.sig" "${archive}" 2>/dev/null; then
          echo ">> GPG 签名验证通过"
        else
          echo ">> 警告: GPG 签名未能验证；要强校验请固定 SHA256。" >&2
        fi
      else
        echo ">> 提示: 本机无 gpg，跳过签名验证；建议固定 SHA256。" >&2
      fi
    fi
  fi

  TOOLCHAIN_PARTIAL="${CE_COMPILERS_ROOT}/.$(basename "${dest}").partial.$$"
  rm -rf -- "${TOOLCHAIN_PARTIAL}"
  mkdir -p "${TOOLCHAIN_PARTIAL}"
  tar -xf "${archive}" -C "${TOOLCHAIN_PARTIAL}" --strip-components=1
  [[ -x "${TOOLCHAIN_PARTIAL}/${required_exe}" ]] \
    || { echo "错误: 归档缺少 ${required_exe}，保留现有工具链不变。" >&2; exit 1; }
  [[ ! -e "${dest}" ]] || rm -rf -- "${dest}"
  mv -T "${TOOLCHAIN_PARTIAL}" "${dest}"
  TOOLCHAIN_PARTIAL=""

  if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
    chcon -R -t container_file_t "${dest}" || true
  fi
}

install_versioned_toolchain() { # <link> <dir-base> <version> <url> <exe> [sha256] [signature-url]
  local link="$1" dirbase="$2" verid="$3" url="$4" exe="$5"
  local expect_sha="${6:-}" sig_url="${7:-}" dest
  verid="${verid//[^A-Za-z0-9._-]/_}"
  [[ -n "${verid}" ]] || { echo "错误: 无法从下载地址得到安全的版本标识。" >&2; exit 1; }
  dest="${CE_COMPILERS_ROOT}/${dirbase}-${verid}"

  if [[ -x "${dest}/${exe}" ]]; then
    if [[ "$(readlink "${CE_COMPILERS_ROOT}/${link}" 2>/dev/null || true)" == "$(basename "${dest}")" ]]; then
      echo ">> [跳过] ${dirbase} 已是 ${verid}，${link} 已正确指向它"
      return
    fi
    echo ">> [修复链接] ${dirbase} ${verid} 已存在，仅重拨 ${link}"
    point_toolchain_link "${link}" "${dest}"
    DID_CHANGE=1
    return
  fi

  echo ">> [更新] ${dirbase} -> ${verid}"
  install_toolchain_tarball "${url}" "${dest}" "${exe}" "${expect_sha}" "${sig_url}"
  point_toolchain_link "${link}" "${dest}"
  DID_CHANGE=1
}

finish_toolchain_update() { # finish_toolchain_update <display-name>
  local display_name="$1"
  if [[ "${DID_CHANGE}" == "1" ]]; then
    if [[ "${CE_DEFER_RESTART:-0}" == "1" ]]; then
      if [[ -n "${CE_RESTART_NEEDED_FILE:-}" ]]; then
        : > "${CE_RESTART_NEEDED_FILE}"
      fi
      echo ">> CE 重启已交给统一工具链更新入口处理"
    else
      # shellcheck source=../lib-vm.sh
      source "${REPO_ROOT}/scripts/lib-vm.sh"
      restart_ce_in_vm
    fi
  else
    echo ">> ${display_name} 已是最新，无需重启 CE"
  fi
  echo ">> ${display_name} 更新完成"
}
