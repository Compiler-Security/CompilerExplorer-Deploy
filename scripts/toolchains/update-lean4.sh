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
LEAN4_SHA256="$(normalize_sha256 LEAN4_SHA256 "${LEAN4_SHA256:-}")"

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
expected_sha="$(normalize_sha256 'Lean release digest' "${expected_sha}")"

install_versioned_toolchain \
  lean-latest lean "${version}" "${url}" "bin/lean bin/leanc" "${expected_sha}"

lean_version="$(detect_semver "${CE_COMPILERS_ROOT}/lean-latest/bin/lean" --version)"
sync_config_property lean.local.properties compiler.lean.name "Lean ${lean_version}"
sync_config_property lean.local.properties compiler.lean.semver "${lean_version}"

finish_toolchain_update "Lean 4"
