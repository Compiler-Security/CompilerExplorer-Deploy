#!/usr/bin/env bash
# =============================================================================
# provision-ce.sh —— 在 VM 里安装 / 升级 CompilerExplorer（直接跑，无内层 docker）。
#   由 cloud-init 首启调用，也可在 VM 里重跑以升级 CE。
#
#   用法（VM 内，root）:
#     provision-ce.sh <ce-tag>           # 例: provision-ce.sh gh-18904
#
#   依赖 QEMU 9p 共享：
#     /opt/compiler-explorer  <- 工具链（只读）
#     /mnt/ce-repo            <- 本仓库（只读；取 config/ 与 scripts/）
# =============================================================================
set -euo pipefail

CE_REF="${1:?用法: provision-ce.sh <ce-tag>  (如 gh-18904)}"
REPO_SRC="${REPO_SRC:-/mnt/ce-repo}"
NODE_VERSION="${NODE_VERSION:-}"          # 空则取 nodejs 最新 v22
CE_HOME=/opt/ce
NODE_HOME=/opt/node
CE_UID=10001
CE_GID=10001

echo ">> provision CE @ ${CE_REF}"

# ---- 1) Node 22（官方 tarball 到 /opt/node；CE 要求 >=22.22.1）----------------
if [[ ! -x "${NODE_HOME}/bin/node" ]]; then
  if [[ -z "${NODE_VERSION}" ]]; then
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ \
      | grep -oE 'node-v22\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz' | head -1 \
      | sed -E 's/node-v(.*)-linux-x64\.tar\.xz/\1/')"
  fi
  [[ -n "${NODE_VERSION}" ]] || { echo "错误: 解析不到 node 版本"; exit 1; }
  echo ">> 安装 node v${NODE_VERSION}"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ -C /opt
  mv "/opt/node-v${NODE_VERSION}-linux-x64" "${NODE_HOME}"
fi
export PATH="${NODE_HOME}/bin:${PATH}"
echo ">> node $(node --version)"

# ---- 2) 构建/运行依赖 ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git build-essential python3 ca-certificates curl cgroup-tools

# ---- 3) ce 用户（uid 10001，CE 进程与 nsjail 用它）------------------------------
id -u ce >/dev/null 2>&1 || {
  groupadd --system --gid "${CE_GID}" ce
  useradd --system --uid "${CE_UID}" --gid ce --home "${CE_HOME}" ce
}

# ---- 4) CE 源码 @ CE_REF -------------------------------------------------------
if [[ -d "${CE_HOME}/.git" ]]; then
  echo ">> 已存在 CE checkout，切换到 ${CE_REF}"
  git -C "${CE_HOME}" fetch --depth 1 origin "refs/tags/${CE_REF}:refs/tags/${CE_REF}" || git -C "${CE_HOME}" fetch --tags
  git -C "${CE_HOME}" checkout -q "${CE_REF}"
else
  echo ">> 克隆 CE @ ${CE_REF}"
  git clone --depth 1 --branch "${CE_REF}" \
    https://github.com/compiler-explorer/compiler-explorer.git "${CE_HOME}"
fi

# ---- 5) 构建（webpack 前端 + tsc 后端）------------------------------------------
echo ">> 构建 CE（首次较慢）"
cd "${CE_HOME}"
npm ci --no-audit --no-fund
npm run webpack
npm run ts-compile
npm prune --omit=dev

# ---- 6) 套用我们的覆盖配置（9p 共享仓库里的 config/）-----------------------------
for f in c++ mlir compiler-explorer execution; do
  cp "${REPO_SRC}/config/${f}.local.properties" "${CE_HOME}/etc/config/${f}.local.properties"
done

# ---- 7) nsjail cgroup 前置（VM 是专用的，用官方写法；幂等）----------------------
CE_UID="${CE_UID}" CE_GID="${CE_GID}" bash "${REPO_SRC}/scripts/setup-nsjail-cgroups.sh" || \
  echo ">> 警告: nsjail cgroup 前置失败（可能已就绪）"

# ---- 8) systemd 服务 -----------------------------------------------------------
chown -R ce:ce "${CE_HOME}"
cp "${REPO_SRC}/vm/ce.service" /etc/systemd/system/ce.service
systemctl daemon-reload
systemctl enable ce.service
systemctl restart ce.service

echo ">> CE @ ${CE_REF} 已起来（systemd: ce.service，监听 0.0.0.0:10240）"
