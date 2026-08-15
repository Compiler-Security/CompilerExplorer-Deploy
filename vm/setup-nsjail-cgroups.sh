#!/usr/bin/env bash
# 在 Ubuntu guest 内创建 nsjail 使用的 cgroup，可安装 systemd 持久化。
set -euo pipefail

CE_UID="${CE_UID:-10001}"
CE_GID="${CE_GID:-10001}"
UNIT=/etc/systemd/system/ce-cgroups.service
CGROUP_ROOT=/sys/fs/cgroup

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
  [[ -f "${CGROUP_ROOT}/cgroup.controllers" ]] \
    || { echo "错误: Ubuntu guest 未使用 cgroup v2。" >&2; exit 1; }

  local controller name path
  for controller in cpu memory pids; do
    grep -qw "${controller}" "${CGROUP_ROOT}/cgroup.controllers" \
      || { echo "错误: cgroup v2 缺少 ${controller} controller。" >&2; exit 1; }
    if ! grep -qw "${controller}" "${CGROUP_ROOT}/cgroup.subtree_control"; then
      printf '+%s\n' "${controller}" > "${CGROUP_ROOT}/cgroup.subtree_control"
    fi
  done

  echo ">> 创建并委托 ce-compile / ce-sandbox（属主 ${CE_UID}:${CE_GID}）"
  for name in ce-compile ce-sandbox; do
    path="${CGROUP_ROOT}/${name}"
    mkdir -p "${path}"
    chown "${CE_UID}:${CE_GID}" \
      "${path}" "${path}/cgroup.procs" "${path}/cgroup.subtree_control"
    [[ ! -e "${path}/cgroup.threads" ]] \
      || chown "${CE_UID}:${CE_GID}" "${path}/cgroup.threads"
    [[ "$(stat -fc %T "${path}")" == "cgroup2fs" ]] \
      || { echo "错误: ${path} 不是 cgroup v2 目录。" >&2; exit 1; }
  done
  chown "${CE_UID}:root" "${CGROUP_ROOT}/cgroup.procs"

  set_sysctl_if_present kernel.unprivileged_userns_clone 1          # Debian/Ubuntu 通用
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 0  # Ubuntu 24.04+
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 0      # Ubuntu 24.04+

  echo ">> cgroup v2 目录已创建并验证"
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
  systemctl enable ce-cgroups.service
  systemctl restart ce-cgroups.service
  echo ">> 已重启并 enable ce-cgroups.service（开机自动重建 cgroup）。"
}

case "${1:-}" in
  "")                do_setup ;;
  --install-systemd) install_systemd ;;
  *) echo "未知参数: $1"; usage; exit 2 ;;
esac
