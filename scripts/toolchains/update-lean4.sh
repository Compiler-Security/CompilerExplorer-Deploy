#!/usr/bin/env bash
# 幂等更新 Lean 4 官方 Linux 工具链，并原子切换 lean-latest。
# 用法：update-lean4.sh [版本号|latest]（默认 latest）
set -euo pipefail

[[ "$#" -le 1 ]] || { echo "用法: $0 [版本号|latest]" >&2; exit 2; }

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_commands python3 zstd
prepare_toolchain_update

REQUESTED_VERSION="${1:-latest}"
LEAN4_ARCHIVE_URL="${LEAN4_ARCHIVE_URL:-}"
LEAN4_SHA256="${LEAN4_SHA256:-}"
[[ -z "${LEAN4_SHA256}" || "${LEAN4_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: LEAN4_SHA256 必须是 64 位十六进制。" >&2; exit 2; }
LEAN4_SHA256="${LEAN4_SHA256,,}"

version=""
url="${LEAN4_ARCHIVE_URL}"
api_sha=""
if [[ -z "${url}" ]]; then
  if [[ "${REQUESTED_VERSION}" == "latest" ]]; then
    release_api="https://api.github.com/repos/leanprover/lean4/releases/latest"
  else
    version="${REQUESTED_VERSION#v}"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
      || { echo "错误: Lean 4 版本格式无效: ${REQUESTED_VERSION}" >&2; exit 2; }
    release_api="https://api.github.com/repos/leanprover/lean4/releases/tags/v${version}"
  fi

  echo ">> 查询 Lean 4 release ..."
  release_json="$(curl -fsSL "${release_api}")"
  mapfile -t release_info < <(
    printf '%s' "${release_json}" | python3 -c '
import json
import sys

release = json.load(sys.stdin)
tag = release["tag_name"]
version = tag.removeprefix("v")
name = f"lean-{version}-linux.tar.zst"
asset = next((item for item in release.get("assets", []) if item.get("name") == name), None)
if asset is None:
    raise SystemExit(f"release {tag} 中找不到 {name}")
print(version)
print(asset["browser_download_url"])
print(asset.get("digest") or "")
'
  )
  version="${release_info[0]:-}"
  url="${release_info[1]:-}"
  api_sha="${release_info[2]:-}"
  api_sha="${api_sha#sha256:}"
  [[ -n "${version}" && -n "${url}" ]] \
    || { echo "错误: 无法解析 Lean 4 release 资产。" >&2; exit 1; }
else
  [[ "${url}" == *.tar.zst ]] \
    || { echo "错误: LEAN4_ARCHIVE_URL 当前只支持 .tar.zst。" >&2; exit 2; }
  if [[ "${REQUESTED_VERSION}" != "latest" ]]; then
    version="${REQUESTED_VERSION#v}"
  elif [[ "${url##*/}" =~ ^lean-([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)-linux\.tar\.zst$ ]]; then
    version="${BASH_REMATCH[1]}"
  else
    echo "错误: 无法从 LEAN4_ARCHIVE_URL 推断版本，请把版本号作为第一个参数。" >&2
    exit 2
  fi
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
    || { echo "错误: Lean 4 版本格式无效: ${version}" >&2; exit 2; }
fi

expected_sha="${LEAN4_SHA256:-${api_sha}}"
[[ -z "${expected_sha}" || "${expected_sha}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: release 返回的 Lean 4 SHA256 格式无效。" >&2; exit 1; }
expected_sha="${expected_sha,,}"

dest="${CE_COMPILERS_ROOT}/lean-${version}"
link="${CE_COMPILERS_ROOT}/lean-latest"
target_name="${dest##*/}"

if [[ -x "${dest}/bin/lean" && -x "${dest}/bin/leanc" ]]; then
  if [[ "$(readlink "${link}" 2>/dev/null || true)" == "${target_name}" ]]; then
    echo ">> [跳过] Lean 4 ${version} 已安装，lean-latest 已正确指向它"
  else
    echo ">> [修复链接] lean-latest -> ${target_name}"
    point_toolchain_link lean-latest "${dest}"
    DID_CHANGE=1
  fi
else
  echo ">> 下载 Lean 4 ${version}: ${url}"
  archive="${TOOLCHAIN_WORK}/lean.tar.zst"
  curl -fSL --retry 3 -o "${archive}" "${url}"
  actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"
  if [[ -n "${expected_sha}" ]]; then
    [[ "${actual_sha}" == "${expected_sha}" ]] \
      || { echo "错误: Lean 4 SHA256 不匹配（期望 ${expected_sha} 实际 ${actual_sha}）。" >&2; exit 1; }
    echo ">> SHA256 校验通过: ${actual_sha}"
  else
    echo ">> 警告: 未提供且 release 未返回 SHA256；本次下载哈希: ${actual_sha}" >&2
  fi

  TOOLCHAIN_PARTIAL="${CE_COMPILERS_ROOT}/.lean-${version}.partial.$$"
  rm -rf -- "${TOOLCHAIN_PARTIAL}"
  mkdir -p "${TOOLCHAIN_PARTIAL}"
  zstd -dc "${archive}" | tar -xf - -C "${TOOLCHAIN_PARTIAL}" --strip-components=1
  [[ -x "${TOOLCHAIN_PARTIAL}/bin/lean" && -x "${TOOLCHAIN_PARTIAL}/bin/leanc" ]] \
    || { echo "错误: Lean 4 归档缺少 bin/lean 或 bin/leanc。" >&2; exit 1; }

  [[ ! -e "${dest}" ]] || rm -rf -- "${dest}"
  mv -T "${TOOLCHAIN_PARTIAL}" "${dest}"
  TOOLCHAIN_PARTIAL=""
  if command -v chcon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
    chcon -R -t container_file_t "${dest}" || true
  fi

  point_toolchain_link lean-latest "${dest}"
  DID_CHANGE=1
fi

lean_version="$(detect_semver "${CE_COMPILERS_ROOT}/lean-latest/bin/lean" --version)"
sync_config_property lean.local.properties compiler.lean.name "Lean ${lean_version}"
sync_config_property lean.local.properties compiler.lean.semver "${lean_version}"

finish_toolchain_update "Lean 4"
