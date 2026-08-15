#!/usr/bin/env bash
# 统一更新标准工具链；自研 MLIR 仍由 deploy-mlir.sh 发布。
# 用法：update-toolchains.sh [Lean版本号|latest]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"; set +a
fi

LEAN_VERSION="${1:-latest}"
[[ "$#" -le 1 ]] || { echo "用法: $0 [Lean版本号|latest]" >&2; exit 2; }

STATE_DIR="$(mktemp -d)"
RESTART_NEEDED_FILE="${STATE_DIR}/restart-needed"
cleanup() {
  rm -f -- "${RESTART_NEEDED_FILE}"
  rmdir -- "${STATE_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

export CE_DEFER_RESTART=1
export CE_RESTART_NEEDED_FILE="${RESTART_NEEDED_FILE}"

echo ">> 更新 Clang、x86_64 GCC 与 riscv64 GCC"
"${REPO_ROOT}/scripts/update-clang-gcc.sh" all

echo ">> 更新 Lean 4（${LEAN_VERSION}）"
"${REPO_ROOT}/scripts/update-lean4.sh" "${LEAN_VERSION}"

unset CE_DEFER_RESTART
unset CE_RESTART_NEEDED_FILE
# shellcheck source=lib-vm.sh
source "${REPO_ROOT}/scripts/lib-vm.sh"
if [[ -f "${RESTART_NEEDED_FILE}" ]]; then
  restart_ce_in_vm
else
  echo ">> 所有标准工具链均已是最新，无需重启 CE"
fi

echo ">> 所有标准工具链更新完成"
