#!/usr/bin/env bash
# =============================================================================
# setup-nsjail-cgroups.sh —— 宿主机 nsjail 前置设置 / 卸载（用 sudo 运行）。
#
#   nsjail 用 cgroup 做内存/CPU/进程数限制，需要两个 cgroup 层级：
#     ce-compile  —— 编译器/工具执行（宽松）
#     ce-sandbox  —— 用户程序执行（严格；仅当 CE 开放“在线运行”时用到）
#   cgroup 目录重启即失，故提供 systemd 持久化（见 --install-systemd）。
#
#   用法:
#     sudo ./setup-nsjail-cgroups.sh                   # 立即设置（本次启动有效）
#     sudo ./setup-nsjail-cgroups.sh --install-systemd  # 设置并装开机自启 unit
#     sudo ./setup-nsjail-cgroups.sh --uninstall        # 卸载：删 unit + 删 cgroup + 还原 sysctl
#
#   关键：CE 在容器内以 uid 10001 运行（compose user: 10001:10001），
#   容器默认无 user-namespace 重映射 → 宿主机上对应同一 uid 10001。
#   因此 ce-* cgroup 与 /sys/fs/cgroup/cgroup.procs 要 chown 给该 uid，
#   否则 nsjail 报 "runChild():486 Launching child process failed"。
# =============================================================================
set -euo pipefail

CE_UID="${CE_UID:-10001}"
CE_GID="${CE_GID:-10001}"
UNIT=/etc/systemd/system/ce-cgroups.service

# 帮助不需要 root。
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行（需要 root 做一次性 cgroup/sysctl 设置）。" >&2
  exit 1
fi

# ---- 判断 cgroup v1 / v2 -----------------------------------------------------
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

# ---- sysctl：按发行版，存在才设置 ---------------------------------------------
set_sysctl_if_present() { # set_sysctl_if_present <key> <val>
  local key="$1" val="$2"
  if sysctl -a 2>/dev/null | grep -q "^${key} "; then
    echo ">> sysctl ${key}=${val}"
    sysctl -w "${key}=${val}"
  fi
}

# =============================================================================
# 设置
# =============================================================================
do_setup() {
  detect_cg_version
  echo ">> 检测到 cgroup v${CG_VERSION}"

  # 确保有 cgcreate（libcgroup / cgroup-tools）
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

  # 允许该 uid 把进程迁入根 cgroup（cgroup v2 需要）
  if [[ "${CG_VERSION}" == "2" ]]; then
    chown "${CE_UID}:root" /sys/fs/cgroup/cgroup.procs
  fi

  # 放开 unprivileged user namespace（按发行版，存在才设置）
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
Before=docker.service

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
  echo ">> 已 enable ce-cgroups.service（重启后自动重建 cgroup）。"
}

# =============================================================================
# 卸载
# =============================================================================
do_uninstall() {
  detect_cg_version
  echo ">> 卸载 nsjail 前置（cgroup v${CG_VERSION}）"

  # 1) 移除 systemd unit（若装过）
  if [[ -f "${UNIT}" ]]; then
    echo ">> 停用并删除 systemd unit: ${UNIT}"
    systemctl disable --now ce-cgroups.service 2>/dev/null || true
    rm -f "${UNIT}"
    systemctl daemon-reload
  else
    echo ">> 未发现 systemd unit，跳过"
  fi

  # 2) 删除两个 cgroup（有进程占用时 cgdelete 会失败，先提示）
  if command -v cgdelete >/dev/null 2>&1; then
    for g in ce-compile ce-sandbox; do
      if cgdelete -g "${CTRL}:${g}" 2>/dev/null; then
        echo ">> 删除 cgroup ${g}"
      else
        echo ">> 警告: 删除 cgroup ${g} 失败（可能仍有进程在里面，或本就不存在）。" >&2
        echo "   若是进程占用，先 docker compose stop ce 再重试。" >&2
      fi
    done
  else
    # 无 cgdelete 时，cgroup v2 可直接 rmdir 空目录
    for g in ce-compile ce-sandbox; do
      rmdir "/sys/fs/cgroup/${g}" 2>/dev/null && echo ">> 删除 cgroup ${g}" \
        || echo ">> 跳过 ${g}（不存在或非空）"
    done
  fi

  # 3) 还原 /sys/fs/cgroup/cgroup.procs 属主（cgroup v2）
  if [[ "${CG_VERSION}" == "2" ]]; then
    chown root:root /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
    echo ">> 还原 /sys/fs/cgroup/cgroup.procs 属主为 root"
  fi

  # 4) 还原 sysctl：重新启用 Ubuntu 24.04+ 的 AppArmor userns 限制（安全默认）。
  #    不动 kernel.unprivileged_userns_clone —— 它默认就该允许，且别的应用可能依赖。
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 1
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 1

  echo ">> 卸载完成。（未触碰工具链目录与 CE 容器，如需一并清理请另行处理）"
}

# =============================================================================
case "${1:-}" in
  "")                do_setup ;;
  --install-systemd) do_setup; install_systemd ;;
  --uninstall|uninstall|remove) do_uninstall ;;
  *) echo "未知参数: $1"; echo "用法: $0 [--install-systemd|--uninstall]"; exit 2 ;;
esac
