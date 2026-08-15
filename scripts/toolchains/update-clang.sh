#!/usr/bin/env bash
# 幂等更新官方预编译 Clang/LLVM，并原子切换 clang-latest。
set -euo pipefail

[[ "$#" -eq 0 ]] || { echo "用法: $0" >&2; exit 2; }

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
prepare_toolchain_update

CLANG_TARBALL_URL="${CLANG_TARBALL_URL:-}"
LLVM_SHA256="${LLVM_SHA256:-}"
[[ -z "${LLVM_SHA256}" || "${LLVM_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: LLVM_SHA256 必须是 64 位十六进制。" >&2; exit 2; }
LLVM_SHA256="${LLVM_SHA256,,}"

url="${CLANG_TARBALL_URL}"
verid=""
if [[ -z "${url}" ]]; then
  echo ">> 查询最新 LLVM release ..."
  release_json="$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest)"
  tag="$(printf '%s\n' "${release_json}" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  tag="${tag%%$'\n'*}"
  [[ -n "${tag}" ]] \
    || { echo "错误: 解析不到 LLVM 最新 tag；可手动设置 CLANG_TARBALL_URL。" >&2; exit 1; }
  verid="${tag#llvmorg-}"
  url="$(printf '%s\n' "${release_json}" \
    | grep -oE 'https://[^"]*(Linux-X64|clang\+llvm[^"]*[Ll]inux[^"]*(x86_64|X64))[^"]*\.tar\.xz' \
    || true)"
  url="${url%%$'\n'*}"
  [[ -n "${url}" ]] \
    || { echo "错误: ${tag} 下找不到 Linux x86_64 预编译包；请设置 CLANG_TARBALL_URL。" >&2; exit 1; }
  echo ">> 最新 LLVM: ${tag}"
else
  verid="$(basename "${url}")"
  verid="${verid%.tar.xz}"
  verid="${verid%.tar.gz}"
fi

install_versioned_toolchain \
  clang-latest clang "${verid}" "${url}" bin/clang++ "${LLVM_SHA256}" "${url}.sig"
finish_toolchain_update "Clang/LLVM"
