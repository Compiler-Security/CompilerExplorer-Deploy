# 共享函数：工具链更新后进 VM 重启 CE（清编译缓存 + 刷新版本显示）。
# 被 update-clang-gcc.sh / deploy-mlir.sh source。
#
# 说明：CE 的编译器 exe 走的是稳定符号链接（如 clang-latest -> 新版本），
# 下次编译本就会用新工具链 —— 重启只是为了立刻清掉 CE 的编译缓存/版本缓存。
# 所以这是 best-effort：没配 SSH 就只提示，不让部署失败。

restart_ce_in_vm() {
  local key="${CE_VM_SSH_KEY:-}"   # 宿主上 ce_vm_key 私钥路径（对应 .env 的 CE_VM_SSH_KEY）
  if [[ -n "${key}" && -f "${key}" ]]; then
    echo ">> SSH 进 VM 重启 CE（清缓存）"
    if ssh -i "${key}" -p "${CE_VM_SSH_PORT:-2222}" \
           -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
           ce@127.0.0.1 'sudo systemctl restart ce.service'; then
      echo ">> CE 已在 VM 内重启"
    else
      echo ">> 警告: SSH 重启 CE 失败（不影响新工具链下次编译生效）" >&2
    fi
  else
    echo ">> 提示: 未配置 CE_VM_SSH_KEY，跳过 VM 内 CE 重启。"
    echo ">>   新工具链下次编译即生效；如需立即清缓存，进 VM 执行: sudo systemctl restart ce.service"
  fi
}
