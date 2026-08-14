#!/usr/bin/env bash
# 创建 nsjail 使用的 ce-compile / ce-sandbox cgroup，可安装 systemd 持久化。
set -euo pipefail

CE_UID="${CE_UID:-10001}"
CE_GID="${CE_GID:-10001}"
UNIT=/etc/systemd/system/ce-cgroups.service

usage() {
  echo "用法: $0 [--install-systemd|--uninstall]"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行（需要 root 做一次性 cgroup/sysctl 设置）。" >&2
  exit 1
fi

detect_cg_version() {
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    CG_VERSION=2; CTRL="memory,pids,cpu"
  elif [[ -d /sys/fs/cgroup/memory ]]; then
    CG_VERSION=1; CTRL="memory,pids,cpu,net_cls"
  else
    echo "未检测到可用的 cgroup v1/v2。" >&2
    exit 1
  fi
}

set_sysctl_if_present() { # set_sysctl_if_present <key> <val>
  local key="$1" val="$2"
  if sysctl -n "${key}" >/dev/null 2>&1; then
    echo ">> sysctl ${key}=${val}"
    sysctl -w "${key}=${val}"
  fi
}

do_setup() {
  detect_cg_version
  echo ">> 检测到 cgroup v${CG_VERSION}"

  if ! command -v cgcreate >/dev/null 2>&1; then
    echo ">> 未找到 cgcreate，尝试安装（Debian/Ubuntu: cgroup-tools；Fedora: libcgroup-tools）"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y cgroup-tools
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y libcgroup-tools
    else
      echo "请手动安装 cgroup-tools / libcgroup-tools 后重跑。" >&2
      exit 1
    fi
  fi

  echo ">> 创建 ce-compile / ce-sandbox（属主 ${CE_UID}:${CE_GID}）"
  cgcreate -a "${CE_UID}:${CE_GID}" -g "${CTRL}:ce-compile"
  cgcreate -a "${CE_UID}:${CE_GID}" -g "${CTRL}:ce-sandbox"

  if [[ "${CG_VERSION}" == "2" ]]; then
    chown "${CE_UID}:root" /sys/fs/cgroup/cgroup.procs
  fi

  set_sysctl_if_present kernel.unprivileged_userns_clone 1          # Debian/Ubuntu 通用
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 0  # Ubuntu 24.04+
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 0      # Ubuntu 24.04+

  echo ">> 完成。ce-compile / ce-sandbox 已就绪（属主 uid ${CE_UID}）。"
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

do_uninstall() {
  detect_cg_version
  echo ">> 卸载 nsjail 前置（cgroup v${CG_VERSION}）"

  if [[ -f "${UNIT}" ]]; then
    echo ">> 停用并删除 systemd unit: ${UNIT}"
    systemctl disable --now ce-cgroups.service 2>/dev/null || true
    rm -f "${UNIT}"
    systemctl daemon-reload
  else
    echo ">> 未发现 systemd unit，跳过"
  fi

  if command -v cgdelete >/dev/null 2>&1; then
    for g in ce-compile ce-sandbox; do
      if cgdelete -g "${CTRL}:${g}" 2>/dev/null; then
        echo ">> 删除 cgroup ${g}"
      else
        echo ">> 警告: 删除 cgroup ${g} 失败（可能仍有进程在里面，或本就不存在）。" >&2
        echo "   若是进程占用，先 systemctl stop ce.service 再重试。" >&2
      fi
    done
  else
    for g in ce-compile ce-sandbox; do
      rmdir "/sys/fs/cgroup/${g}" 2>/dev/null && echo ">> 删除 cgroup ${g}" \
        || echo ">> 跳过 ${g}（不存在或非空）"
    done
  fi

  if [[ "${CG_VERSION}" == "2" ]]; then
    chown root:root /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
    echo ">> 还原 /sys/fs/cgroup/cgroup.procs 属主为 root"
  fi

  # 恢复 Ubuntu 24.04+ AppArmor 默认；不改可能被其它应用依赖的 userns_clone。
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 1
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 1

  echo ">> 卸载完成。（未触碰工具链目录与 CE 容器，如需一并清理请另行处理）"
}

case "${1:-}" in
  "")                do_setup ;;
  --install-systemd) install_systemd ;;
  --uninstall|uninstall|remove) do_uninstall ;;
  *) echo "未知参数: $1"; usage; exit 2 ;;
esac
