#!/usr/bin/env bash
# =============================================================================
# provision-ce.sh —— 在 VM 里安装 / 升级 CompilerExplorer（直接跑，无内层 docker）。
#   由 cloud-init 首启调用，也可在 VM 里重跑以升级 CE。**fail-closed**：任一步失败
#   即非零退出，不会带半成品起 CE。
#
#   用法（VM 内，root）:
#     provision-ce.sh <ce-tag>           # 例: provision-ce.sh gh-18904
#
#   依赖 QEMU 9p 共享：
#     /opt/compiler-explorer  <- 工具链（只读）
#     /mnt/ce-repo            <- 本仓库（只读；取 config/ 与 scripts/）
#   环境变量：NODE_VERSION（空=取 nodejs 最新 v22）、NODE_SHA256（可选钉值）
# =============================================================================
set -euo pipefail

CE_REF="${1:?用法: provision-ce.sh <ce-tag>  (如 gh-18904)}"
REPO_SRC="${REPO_SRC:-/mnt/ce-repo}"
NODE_VERSION="${NODE_VERSION:-}"
NODE_SHA256="${NODE_SHA256:-}"
CE_HOME=/opt/ce
NODE_HOME=/opt/node
NSJAIL_SRC=/opt/nsjail-src
CE_UID=10001
CE_GID=10001

echo ">> provision CE @ ${CE_REF}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# 构建 CE（node 原生扩展）+ 构建 nsjail 的依赖 + 运行库
apt-get install -y -qq --no-install-recommends \
  git build-essential python3 ca-certificates curl xz-utils \
  cgroup-tools \
  autoconf bison flex g++ make pkg-config libtool protobuf-compiler \
  libprotobuf-dev libnl-route-3-dev \
  libprotobuf32 libnl-route-3-200

# ---- 1) Node 22（官方 tarball 到 /opt/node；CE 要求 >=22.22.1）----------------
if [[ ! -x "${NODE_HOME}/bin/node" ]]; then
  if [[ -z "${NODE_VERSION}" ]]; then
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ \
      | grep -oE 'node-v22\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz' | head -1 \
      | sed -E 's/node-v(.*)-linux-x64\.tar\.xz/\1/')"
  fi
  [[ -n "${NODE_VERSION}" ]] || { echo "错误: 解析不到 node 版本"; exit 1; }
  echo ">> 安装 node v${NODE_VERSION}"
  tar_ball="node-v${NODE_VERSION}-linux-x64.tar.xz"
  curl -fsSL -o "/tmp/${tar_ball}" "https://nodejs.org/dist/v${NODE_VERSION}/${tar_ball}"
  # 完整性校验：钉了 NODE_SHA256 用它；否则用 nodejs 官方 SHASUMS256.txt 核对
  if [[ -n "${NODE_SHA256}" ]]; then
    expect="${NODE_SHA256}"
  else
    expect="$(curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
      | grep " ${tar_ball}\$" | awk '{print $1}')"
  fi
  actual="$(sha256sum "/tmp/${tar_ball}" | awk '{print $1}')"
  [[ -n "${expect}" && "${actual}" == "${expect}" ]] \
    || { echo "错误: node tarball SHA256 不匹配（期望 ${expect} 实际 ${actual}）"; exit 1; }
  echo ">> node tarball SHA256 校验通过"
  tar -xJ -C /opt -f "/tmp/${tar_ball}"
  mv "/opt/node-v${NODE_VERSION}-linux-x64" "${NODE_HOME}"
  rm -f "/tmp/${tar_ball}"
fi
export PATH="${NODE_HOME}/bin:${PATH}"
echo ">> node $(node --version)"

# ---- 2) nsjail（CE fork，分支 ce）—— 编译并装到 /usr/local/bin -----------------
if [[ ! -x /usr/local/bin/nsjail ]]; then
  echo ">> 编译安装 nsjail（compiler-explorer/nsjail@ce）"
  rm -rf "${NSJAIL_SRC}"
  git clone --depth 1 --branch ce --recurse-submodules --shallow-submodules \
    https://github.com/compiler-explorer/nsjail.git "${NSJAIL_SRC}"
  make -C "${NSJAIL_SRC}" -j"$(nproc)"
  cp "${NSJAIL_SRC}/nsjail" /usr/local/bin/nsjail
  chmod 0755 /usr/local/bin/nsjail
fi
nsjail --version >/dev/null   # fail-closed：装不上就在这里失败，不起 CE

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

# ---- 6) 套用我们的覆盖配置 —— 用符号链接指向 9p 实时共享，改配置后 restart 即生效 ---
for f in c++ mlir compiler-explorer execution; do
  ln -sfn "${REPO_SRC}/config/${f}.local.properties" "${CE_HOME}/etc/config/${f}.local.properties"
done

# ---- 7) nsjail cgroup 前置（官方写法 + systemd 持久化，重启不丢；fail-closed）-----
CE_UID="${CE_UID}" CE_GID="${CE_GID}" bash "${REPO_SRC}/scripts/setup-nsjail-cgroups.sh" --install-systemd

# ---- 8) systemd 服务 -----------------------------------------------------------
chown -R ce:ce "${CE_HOME}"
cp "${REPO_SRC}/vm/ce.service" /etc/systemd/system/ce.service
systemctl daemon-reload
systemctl enable ce.service
systemctl restart ce.service

# 启起来后快速自检：等 10240 健康检查通过，否则 fail-closed
echo ">> 等待 CE 健康检查 ..."
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:10240/healthcheck >/dev/null 2>&1; then
    echo ">> CE @ ${CE_REF} 已就绪（systemd: ce.service，0.0.0.0:10240）"
    exit 0
  fi
  sleep 2
done
echo "错误: CE 启动后健康检查未通过。查看: journalctl -u ce -e" >&2
exit 1
