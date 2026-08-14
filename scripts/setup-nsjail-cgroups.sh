#!/usr/bin/env bash
# =============================================================================
# setup-nsjail-cgroups.sh —— 宿主机 nsjail cgroup 委派（共享机安全版）/ 卸载。
#
#   适用：共享 / 多租户机器。与官方 NsjailSandbox.md 的区别是 ——
#   **不 chown 根 /sys/fs/cgroup/cgroup.procs**（那样会让 CE 容器能跨租户
#   迁移进程、绕过别人的资源限制）。改为委派一个独立子树 /sys/fs/cgroup/ce，
#   CE 容器用 cgroup_parent 放进该子树，ce-compile/ce-sandbox 建在子树内，
#   迁移的「公共祖先」就是 /ce（已 chown 给 CE 用户），根 cgroup.procs 保持
#   root:root 不动 → 其它租户不受影响。
#
#   仅支持 cgroup v2（现代发行版）。cgroup v1 的委派模型不同，本脚本不处理。
#
#   结构:
#     /sys/fs/cgroup/ce            <- 委派父组(chown 给 CE_UID)
#       ├── ce-compile             <- 编译器 jail 的父组
#       ├── ce-sandbox             <- 用户程序 jail 的父组
#       └── <容器 cgroup>          <- CE 容器(cgroup_parent=/ce)
#
#   用法:
#     sudo ./setup-nsjail-cgroups.sh                   # 立即设置（本次启动有效）
#     sudo ./setup-nsjail-cgroups.sh --install-systemd  # 设置并装开机自启 unit
#     sudo ./setup-nsjail-cgroups.sh --uninstall        # 卸载（先停 CE 容器）
#
#   关键：CE 在容器内以 uid 10001 运行（compose user: 10001:10001），容器默认
#   无 user-namespace 重映射 → 宿主机上对应同一 uid 10001，故把 /ce 子树
#   chown 给该 uid。
# =============================================================================
set -euo pipefail

CE_UID="${CE_UID:-10001}"
CE_GID="${CE_GID:-10001}"
CE_PARENT="${CE_PARENT:-/sys/fs/cgroup/ce}"   # 委派子树根
UNIT=/etc/systemd/system/ce-cgroups.service
CTRLS="memory pids cpu"

# 帮助不需要 root。
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行（需要 root 做一次性 cgroup/sysctl 设置）。" >&2
  exit 1
fi

if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
  echo "错误: 未检测到 cgroup v2（/sys/fs/cgroup/cgroup.controllers 不存在）。" >&2
  echo "     共享机委派模式仅支持 cgroup v2；v1 机器请改用单租户或纯容器方案。" >&2
  exit 1
fi

# ---- sysctl：按发行版，存在才设置 ---------------------------------------------
set_sysctl_if_present() { # set_sysctl_if_present <key> <val>
  local key="$1" val="$2"
  if sysctl -a 2>/dev/null | grep -q "^${key} "; then
    echo ">> sysctl ${key}=${val}"
    sysctl -w "${key}=${val}"
  fi
}

# 往某 cgroup 的 subtree_control 加控制器（逐容错并提示，不静默）。
enable_subtree() { # enable_subtree <cgroup-dir>
  local d="$1" c
  for c in ${CTRLS}; do
    if echo "+${c}" > "${d}/cgroup.subtree_control" 2>/dev/null; then
      echo ">> ${d} subtree_control +${c}"
    else
      echo ">> 警告: ${d} 开启 +${c} 失败（该控制器不可用或该组内有进程）" >&2
    fi
  done
}

# =============================================================================
# 设置
# =============================================================================
do_setup() {
  # 1) 根节点对子组放开控制器。root 不受 no-internal-process 约束；此操作只是
  #    「允许子组使用这些控制器」，不授予任何用户任何权限，对其它租户无影响。
  echo ">> 根节点放开控制器（仅配置，非授权）"
  enable_subtree /sys/fs/cgroup

  # 2) 建委派父组与两个 jail 父组
  mkdir -p "${CE_PARENT}/ce-compile" "${CE_PARENT}/ce-sandbox"

  # 3) 让父组/子组能把控制器继续下放（nsjail 运行时会在它们下面再建 jail 子组）
  enable_subtree "${CE_PARENT}"
  enable_subtree "${CE_PARENT}/ce-compile"
  enable_subtree "${CE_PARENT}/ce-sandbox"

  # 4) 把整个 /ce 子树 chown 给 CE 用户 —— 委派完成。根 cgroup.procs 不动。
  chown -R "${CE_UID}:${CE_GID}" "${CE_PARENT}"
  echo ">> 已把 ${CE_PARENT} 委派给 uid ${CE_UID}（根 cgroup.procs 保持 root:root）"

  # 5) nsjail 仍需 user namespace（与 cgroup 无关；共享机上请知悉这对所有
  #    非特权进程放开 userns，若不可接受见 README 权衡）。
  set_sysctl_if_present kernel.unprivileged_userns_clone 1          # Debian/Ubuntu
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 0  # Ubuntu 24.04+
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 0      # Ubuntu 24.04+

  cat <<EOF
>> 完成。接下来务必在目标机验证「容器落进了委派子树」：
     docker compose up -d ce
     docker inspect ce-app --format '{{.Id}}'   # 拿容器 id
     systemd-cgls ${CE_PARENT}                 # 应能看到容器进程挂在 ${CE_PARENT} 下
   若容器没落在 ${CE_PARENT} 下（docker 用 systemd cgroup 驱动时路径形式不同），
   见 README「共享机 cgroup 委派」一节的处理。
EOF
}

install_systemd() {
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  echo ">> 写入 systemd unit: ${UNIT}（指向 ${script_path}）"
  cat > "${UNIT}" <<EOF
[Unit]
Description=Create Compiler Explorer nsjail delegated cgroup subtree
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
Environment=CE_UID=${CE_UID} CE_GID=${CE_GID} CE_PARENT=${CE_PARENT}
ExecStart=${script_path}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ce-cgroups.service
  echo ">> 已 enable ce-cgroups.service（重启后自动重建委派子树）。"
}

# =============================================================================
# 卸载
# =============================================================================
do_uninstall() {
  echo ">> 卸载 nsjail 委派子树 ${CE_PARENT}"

  # 1) 移除 systemd unit（若装过）
  if [[ -f "${UNIT}" ]]; then
    echo ">> 停用并删除 systemd unit: ${UNIT}"
    systemctl disable --now ce-cgroups.service 2>/dev/null || true
    rm -f "${UNIT}"
    systemctl daemon-reload
  fi

  # 2) 收回委派子树。先停掉各层控制器下放，再自底向上 rmdir。
  #    容器必须已停（否则 ${CE_PARENT} 下还有容器 cgroup，rmdir 会失败）。
  for d in "${CE_PARENT}/ce-compile" "${CE_PARENT}/ce-sandbox" "${CE_PARENT}"; do
    [[ -d "${d}" ]] || continue
    for c in ${CTRLS}; do echo "-${c}" > "${d}/cgroup.subtree_control" 2>/dev/null || true; done
  done
  if rmdir "${CE_PARENT}/ce-compile" "${CE_PARENT}/ce-sandbox" "${CE_PARENT}" 2>/dev/null; then
    echo ">> 已删除 ${CE_PARENT} 子树"
  else
    echo ">> 警告: ${CE_PARENT} 未能完全删除（多半 CE 容器还在运行）。先 docker compose stop ce 再重试。" >&2
  fi

  # 3) 还原 AppArmor userns 限制（安全默认）。根 subtree_control 不收回 ——
  #    它常被 systemd/其它服务使用，且只是「允许子组用控制器」，无害。
  #    不动 kernel.unprivileged_userns_clone（别的应用可能依赖）。
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_unconfined 1
  set_sysctl_if_present kernel.apparmor_restrict_unprivileged_userns 1

  echo ">> 卸载完成。（未触碰工具链目录与 CE 容器镜像；根 subtree_control 保持原样）"
}

# =============================================================================
case "${1:-}" in
  "")                do_setup ;;
  --install-systemd) do_setup; install_systemd ;;
  --uninstall|uninstall|remove) do_uninstall ;;
  *) echo "未知参数: $1"; echo "用法: $0 [--install-systemd|--uninstall]"; exit 2 ;;
esac
