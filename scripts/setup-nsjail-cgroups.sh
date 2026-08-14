#!/usr/bin/env bash
# =============================================================================
# setup-nsjail-cgroups.sh —— 宿主机一次性 nsjail 前置设置（用 sudo 运行）。
#
#   nsjail 用 cgroup 做内存/CPU/进程数限制，需要两个 cgroup 层级：
#     ce-compile  —— 编译器/工具执行（宽松）
#     ce-sandbox  —— 用户程序执行（严格；仅当 CE 开放“在线运行”时用到）
#   cgroup 目录重启即失，故提供 systemd 持久化（见 --install-systemd）。
#
#   用法:
#     sudo ./setup-nsjail-cgroups.sh                  # 立即设置（本次启动有效）
#     sudo ./setup-nsjail-cgroups.sh --install-systemd # 设置并装开机自启 unit
#
#   关键：CE 在容器内以 uid 10001 运行（compose user: 10001:10001），
#   容器默认无 user-namespace 重映射 → 宿主机上对应同一 uid 10001。
#   因此 ce-* cgroup 与 /sys/fs/cgroup/cgroup.procs 要 chown 给该 uid，
#   否则 nsjail 报 "runChild():486 Launching child process failed"。
# =============================================================================
set -euo pipefail

CE_UID="${CE_UID:-10001}"
CE_GID="${CE_GID:-10001}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行（需要 root 做一次性 cgroup/sysctl 设置）。" >&2
  exit 1
fi

# ---- 判断 cgroup v1 / v2 -----------------------------------------------------
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  CG_VERSION=2
elif [[ -d /sys/fs/cgroup/memory ]]; then
  CG_VERSION=1
else
  echo "未检测到可用的 cgroup v1/v2。" >&2
  exit 1
fi
echo ">> 检测到 cgroup v${CG_VERSION}"

# ---- 确保有 cgcreate（libcgroup / cgroup-tools）-----------------------------
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

# ---- 创建 cgroup（v2 用 memory,pids,cpu；v1 另加 net_cls）------------------
if [[ "${CG_VERSION}" == "2" ]]; then
  CTRL="memory,pids,cpu"
else
  CTRL="memory,pids,cpu,net_cls"
fi

echo ">> 创建 ce-compile / ce-sandbox（属主 ${CE_UID}:${CE_GID}）"
cgcreate -a "${CE_UID}:${CE_GID}" -g "${CTRL}:ce-compile"
cgcreate -a "${CE_UID}:${CE_GID}" -g "${CTRL}:ce-sandbox"

# 允许该 uid 把进程迁入根 cgroup（cgroup v2 需要）
if [[ "${CG_VERSION}" == "2" ]]; then
  chown "${CE_UID}:root" /sys/fs/cgroup/cgroup.procs
fi

# ---- 放开 unprivileged user namespace（按发行版，存在才设置）----------------
set_sysctl_if_present() {
  local key="$1" val="$2"
  if sysctl -a 2>/dev/null | grep -q "^${key} "; then
    echo ">> sysctl ${key}=${val}"
    sysctl -w "${key}=${val}"
  fi
}
# Debian/Ubuntu 通用
set_sysctl_if_present kernel.unprivileged_userns_clone 1
# Ubuntu 24.04+ AppArmor 对 userns 的限制
set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 0
set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 0

echo ">> 完成。ce-compile / ce-sandbox 已就绪（属主 uid ${CE_UID}）。"

# ---- 可选：安装 systemd 开机自启 ---------------------------------------------
if [[ "${1:-}" == "--install-systemd" ]]; then
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  UNIT=/etc/systemd/system/ce-cgroups.service
  echo ">> 写入 systemd unit: ${UNIT}（指向 ${SCRIPT_PATH}）"
  cat > "${UNIT}" <<EOF
[Unit]
Description=Create Compiler Explorer nsjail cgroups
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
Environment=CE_UID=${CE_UID} CE_GID=${CE_GID}
ExecStart=${SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ce-cgroups.service
  echo ">> 已 enable ce-cgroups.service（重启后自动重建 cgroup）。"
fi
