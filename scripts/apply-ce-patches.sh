#!/usr/bin/env bash
# 按四位数字文件名前缀的顺序幂等应用 CE 下游补丁。
set -euo pipefail
export LC_ALL=C

CE_TREE="${1:?用法: apply-ce-patches.sh <CE 源码目录> [补丁目录]}"
PATCH_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../vm/patches" && pwd)}"
PATCH_DIR="$(cd "${PATCH_DIR}" && pwd)"

[[ -d "${CE_TREE}/.git" ]] \
  || { echo "错误: 不是 CE Git 工作树: ${CE_TREE}" >&2; exit 1; }

shopt -s nullglob
patches=("${PATCH_DIR}"/[0-9][0-9][0-9][0-9]-*.patch)

for patch_file in "${patches[@]}"; do
  patch_name="${patch_file##*/}"

  if git -C "${CE_TREE}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
    echo ">> [跳过] CE 补丁已应用: ${patch_name}"
  else
    echo ">> 应用 CE 补丁: ${patch_name}"
    git -C "${CE_TREE}" apply --check "${patch_file}"
    git -C "${CE_TREE}" apply "${patch_file}"
  fi
done

echo ">> CE 补丁队列完成（${#patches[@]} 个）"
