#!/usr/bin/env bash
# 在 Ubuntu guest 内创建 nsjail 使用的 cgroup，可安装 systemd 持久化。
set -euo pipefail

CE_UID="${CE_UID:-10001}"
CE_GID="${CE_GID:-10001}"
UNIT=/etc/systemd/system/ce-cgroups.service

usage() {
  echo "用法: $0 [--install-systemd]"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行（需要 root 做一次性 cgroup/sysctl 设置）。" >&2
  exit 1
fi

set_sysctl_if_present() { # set_sysctl_if_present <key> <val>
  local key="$1" val="$2"
  if sysctl -n "${key}" >/dev/null 2>&1; then
    echo ">> sysctl ${key}=${val}"
    sysctl -w "${key}=${val}"
  fi
}

do_setup() {
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] \
    || { echo "错误: Ubuntu guest 未使用 cgroup v2。" >&2; exit 1; }
  command -v cgcreate >/dev/null 2>&1 \
    || { echo "错误: 缺少 cgroup-tools 提供的 cgcreate。" >&2; exit 1; }

  echo ">> 创建 ce-compile / ce-sandbox（属主 ${CE_UID}:${CE_GID}）"
  cgcreate -a "${CE_UID}:${CE_GID}" -g memory,pids,cpu:ce-compile
  cgcreate -a "${CE_UID}:${CE_GID}" -g memory,pids,cpu:ce-sandbox
  chown "${CE_UID}:root" /sys/fs/cgroup/cgroup.procs

  set_sysctl_if_present kernel.unprivileged_userns_clone 1          # Debian/Ubuntu 通用
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 0  # Ubuntu 24.04+
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 0      # Ubuntu 24.04+

  echo ">> ce-compile / ce-sandbox 已就绪"
}

install_systemd() {
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  echo ">> 写入 systemd unit: ${UNIT}（指向 ${script_path}）"
  cat > "${UNIT}" <<EOF
[Unit]
Description=Create Compiler Explorer nsjail cgroups
After=local-fs.target
Before=ce.service
RequiresMountsFor=$(dirname "${script_path}")

[Service]
Type=oneshot
Environment=CE_UID=${CE_UID} CE_GID=${CE_GID}
ExecStart=${script_path}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ce-cgroups.service
  echo ">> 已启动并 enable ce-cgroups.service（重启后自动重建 cgroup）。"
}

case "${1:-}" in
  "")                do_setup ;;
  --install-systemd) install_systemd ;;
  *) echo "未知参数: $1"; usage; exit 2 ;;
esac
