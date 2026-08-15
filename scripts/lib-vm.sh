# 工具链更新后 best-effort 重启 VM 内 CE，以清理缓存并刷新版本显示。

restart_ce_in_vm() {
  local key="${CE_VM_SSH_KEY:-}"
  if [[ -n "${key}" && -f "${key}" ]]; then
    echo ">> SSH 进 VM 重启 CE（清缓存）"
    if ssh -i "${key}" -p "${CE_VM_SSH_PORT:-2223}" \
           -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes -o LogLevel=ERROR \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           ce@127.0.0.1 'sudo systemctl restart ce.service'; then
      echo ">> CE 已在 VM 内重启"
    else
      echo ">> 警告: SSH 重启 CE 失败；请手动重启 CE 以刷新编译器列表。" >&2
    fi
  else
    echo ">> 提示: 未配置 CE_VM_SSH_KEY，跳过 VM 内 CE 重启。"
    echo ">>   请执行 docker compose restart qemu，"
    echo ">>   或进 VM 执行 sudo systemctl restart ce.service，以刷新编译器列表。"
  fi
}
