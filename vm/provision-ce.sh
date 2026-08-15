#!/usr/bin/env bash
# 在 VM 内装配 CE + Node + nsjail；用法：provision-ce.sh <ce-tag>
set -euo pipefail

CE_REF="${1:?用法: provision-ce.sh <ce-tag>  (如 gh-18904)}"
[[ "${CE_REF}" =~ ^gh-[0-9]+$ ]] \
  || { echo "错误: CE tag 格式应为 gh-<数字>。" >&2; exit 2; }
REPO_SRC="${REPO_SRC:-/mnt/ce-repo}"
NODE_VERSION="${NODE_VERSION:-}"
NODE_SHA256="${NODE_SHA256:-}"
node_version_supported() {
  local version="$1" node_major node_minor node_patch
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r node_major node_minor node_patch <<< "${version}"
  (( 10#${node_major} > 22 \
     || (10#${node_major} == 22 && 10#${node_minor} > 22) \
     || (10#${node_major} == 22 && 10#${node_minor} == 22 && 10#${node_patch} >= 1) ))
}
[[ -z "${NODE_VERSION}" || "${NODE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "错误: NODE_VERSION 必须是纯版本号（例如 22.22.1）。" >&2; exit 2; }
[[ -z "${NODE_VERSION}" ]] || node_version_supported "${NODE_VERSION}" \
  || { echo "错误: 当前 CE 要求 Node >= 22.22.1。" >&2; exit 2; }
[[ -z "${NODE_SHA256}" || "${NODE_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: NODE_SHA256 必须是 64 位十六进制。" >&2; exit 2; }
NODE_SHA256="${NODE_SHA256,,}"
CE_HOME=/opt/ce
NODE_HOME=/opt/node
NSJAIL_SRC=/opt/nsjail-src
CE_UID=10001
CE_GID=10001

echo ">> provision CE @ ${CE_REF}"
export DEBIAN_FRONTEND=noninteractive

if systemctl cat ce.service >/dev/null 2>&1; then
  systemctl stop ce.service
fi

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git build-essential python3 ca-certificates curl xz-utils \
  cgroup-tools \
  autoconf bison flex pkg-config libtool protobuf-compiler \
  libprotobuf-dev libnl-route-3-dev

# Node 22（CE 要求 >= 22.22.1）
if [[ ! -x "${NODE_HOME}/bin/node" ]]; then
  if [[ -z "${NODE_VERSION}" ]]; then
    node_index="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/)"
    node_asset="$(printf '%s\n' "${node_index}" \
      | grep -oE 'node-v22\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz' || true)"
    node_asset="${node_asset%%$'\n'*}"
    NODE_VERSION="${node_asset#node-v}"
    NODE_VERSION="${NODE_VERSION%-linux-x64.tar.xz}"
  fi
  [[ -n "${NODE_VERSION}" ]] || { echo "错误: 解析不到 node 版本"; exit 1; }
  node_version_supported "${NODE_VERSION}" \
    || { echo "错误: 当前 CE 要求 Node >= 22.22.1，解析到 v${NODE_VERSION}。" >&2; exit 1; }
  echo ">> 安装 node v${NODE_VERSION}"
  tar_ball="node-v${NODE_VERSION}-linux-x64.tar.xz"
  curl -fsSL -o "/tmp/${tar_ball}" "https://nodejs.org/dist/v${NODE_VERSION}/${tar_ball}"
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
  rm -rf "/opt/node-v${NODE_VERSION}-linux-x64"
  tar -xJ -C /opt -f "/tmp/${tar_ball}"
  rm -rf "${NODE_HOME}"  # 清理上次失败留下的半成品。
  mv "/opt/node-v${NODE_VERSION}-linux-x64" "${NODE_HOME}"
  rm -f "/tmp/${tar_ball}"
fi
export PATH="${NODE_HOME}/bin:${PATH}"
INSTALLED_NODE_VERSION="$(node --version)"
INSTALLED_NODE_VERSION="${INSTALLED_NODE_VERSION#v}"
node_version_supported "${INSTALLED_NODE_VERSION}" \
  || { echo "错误: 已安装 Node v${INSTALLED_NODE_VERSION}，但当前 CE 要求 >= 22.22.1。" >&2; exit 1; }
if [[ -n "${NODE_VERSION}" && "${INSTALLED_NODE_VERSION}" != "${NODE_VERSION}" ]]; then
  echo "错误: 已安装 Node v${INSTALLED_NODE_VERSION}，请求的是 v${NODE_VERSION}；请重建 VM 后装配。" >&2
  exit 1
fi
echo ">> node v${INSTALLED_NODE_VERSION}"

# nsjail（Compiler Explorer fork）
if [[ ! -x /usr/local/bin/nsjail ]]; then
  echo ">> 编译安装 nsjail（compiler-explorer/nsjail@ce）"
  rm -rf "${NSJAIL_SRC}"
  git clone --depth 1 --branch ce --recurse-submodules --shallow-submodules \
    https://github.com/compiler-explorer/nsjail.git "${NSJAIL_SRC}"
  # GCC 15（Ubuntu 26.04）新增 enum/int 条件表达式的 -Wextra 诊断；
  # 保留其余 -Werror，仅将 Wextra 降为普通警告。
  printf '\nCXXFLAGS += -Wno-error=extra\n' >> "${NSJAIL_SRC}/Makefile"
  make -C "${NSJAIL_SRC}" -j"$(nproc)"
  cp "${NSJAIL_SRC}/nsjail" /usr/local/bin/nsjail
  chmod 0755 /usr/local/bin/nsjail
  rm -rf "${NSJAIL_SRC}"
fi
[[ -x /usr/local/bin/nsjail ]] \
  || { echo "错误: nsjail 未正确安装。" >&2; exit 1; }

# ce 用户
if id -u ce >/dev/null 2>&1; then
  [[ "$(id -u ce)" == "${CE_UID}" ]] \
    || { echo "错误: 现有 ce 用户 uid 不是 ${CE_UID}" >&2; exit 1; }
  CE_GID="$(id -g ce)"
else
  groupadd --system --gid "${CE_GID}" ce
  useradd --system --uid "${CE_UID}" --gid ce --home "${CE_HOME}" ce
fi

# CE 源码
if [[ -d "${CE_HOME}/.git" ]]; then
  echo ">> 已存在 CE checkout，切换到 ${CE_REF}"
  git -C "${CE_HOME}" fetch --depth 1 origin "refs/tags/${CE_REF}:refs/tags/${CE_REF}" || git -C "${CE_HOME}" fetch --tags
  git -C "${CE_HOME}" checkout -q "${CE_REF}"
else
  echo ">> 克隆 CE @ ${CE_REF}"
  rm -rf "${CE_HOME}"  # 清理上次失败留下的非 Git 目录。
  git clone --depth 1 --branch "${CE_REF}" \
    https://github.com/compiler-explorer/compiler-explorer.git "${CE_HOME}"
fi

bash "${REPO_SRC}/scripts/apply-ce-patches.sh" \
  "${CE_HOME}" "${REPO_SRC}/vm/patches"

echo ">> 构建 CE（首次较慢）"
cd "${CE_HOME}"
CYPRESS_INSTALL_BINARY=0 npm ci --no-audit --no-fund
npm run webpack
npm run ts-compile
npm prune --omit=dev
npm cache clean --force

# 配置走 9p 软链；服务每次启动还会重新同步，新增语言无需再次装配 VM。
bash "${REPO_SRC}/vm/sync-ce-config.sh" "${CE_HOME}" "${REPO_SRC}"

CE_UID="${CE_UID}" CE_GID="${CE_GID}" bash "${REPO_SRC}/vm/setup-nsjail-cgroups.sh" --install-systemd

chown -R ce:ce "${CE_HOME}"
cp "${REPO_SRC}/vm/ce.service" /etc/systemd/system/ce.service
systemctl daemon-reload
systemctl enable ce.service
systemctl restart ce.service

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
