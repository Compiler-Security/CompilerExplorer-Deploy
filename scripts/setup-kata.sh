#!/usr/bin/env bash
# =============================================================================
# setup-kata.sh —— 在宿主机安装 Kata Containers 并注册进 dockerd（用 sudo 运行）。
#
#   Docker 默认只带 runc；Kata 是独立项目，本脚本装 kata-static 并注册成名为
#   `kata` 的 runtime，之后 docker-compose.yml 里的 `runtime: kata` 才生效。
#
#   用法:
#     sudo ./setup-kata.sh              # 装最新 kata-static + 注册 + 重启 dockerd
#     KATA_VERSION=4.0.0 sudo ./setup-kata.sh   # 钉版本
#     KATA_SHA256=<hex>  sudo ./setup-kata.sh   # 钉 SHA256 做完整性校验（不符即中止）
#
#   前提: 宿主机有 /dev/kvm。装完请按脚本末尾的验证步骤确认。
# =============================================================================
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行。" >&2
  exit 1
fi

if [[ ! -c /dev/kvm ]]; then
  echo "错误: 没有 /dev/kvm。Kata 需要硬件虚拟化（若本机是 VM，需开嵌套虚拟化）。" >&2
  exit 1
fi

KATA_VERSION="${KATA_VERSION:-}"
KATA_SHA256="${KATA_SHA256:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---- 解析要装的版本与下载地址 -------------------------------------------------
if [[ -z "${KATA_VERSION}" ]]; then
  echo ">> 查询 kata-containers 最新 release ..."
  json="$(curl -fsSL https://api.github.com/repos/kata-containers/kata-containers/releases/latest)"
  KATA_VERSION="$(printf '%s\n' "${json}" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  KATA_VERSION="${KATA_VERSION%%$'\n'*}"
fi
[[ -n "${KATA_VERSION}" ]] || { echo "错误: 解析不到 Kata 版本；请 KATA_VERSION=... 指定"; exit 1; }
URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst"
echo ">> 目标版本 ${KATA_VERSION}: ${URL}"

# ---- 幂等：该版本已装则跳过下载 ----------------------------------------------
if [[ -x /opt/kata/bin/kata-runtime ]] && /opt/kata/bin/kata-runtime --version 2>/dev/null | grep -q "${KATA_VERSION}"; then
  echo ">> Kata ${KATA_VERSION} 已安装，跳过下载/解压"
else
  echo ">> 下载并解压 kata-static ..."
  curl -fSL --retry 3 -o "${WORK}/kata.tar.zst" "${URL}"

  # 完整性校验：钉了 KATA_SHA256 就强制比对
  actual="$(sha256sum "${WORK}/kata.tar.zst" | awk '{print $1}')"
  if [[ -n "${KATA_SHA256}" ]]; then
    [[ "${actual}" == "${KATA_SHA256}" ]] \
      || { echo "错误: SHA256 不匹配！期望 ${KATA_SHA256} 实际 ${actual}。已中止。" >&2; exit 1; }
    echo ">> SHA256 校验通过"
  else
    echo ">> 未固定 KATA_SHA256。本次哈希: ${actual}（核对官方后可钉）"
  fi

  command -v zstd >/dev/null 2>&1 || {
    echo ">> 安装 zstd（解压 .tar.zst 需要）"
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y zstd
    elif command -v dnf >/dev/null 2>&1; then dnf install -y zstd
    else echo "请手动安装 zstd"; exit 1; fi
  }
  # kata-static 顶层是 opt/kata，解压到 / 得到 /opt/kata
  tar --zstd -xf "${WORK}/kata.tar.zst" -C /
  echo ">> 已解压到 /opt/kata"
fi

# ---- 让 dockerd 的 containerd 能找到 shim / runtime ---------------------------
mkdir -p /usr/local/bin
ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

# ---- 注册 runtime 进 /etc/docker/daemon.json（合并，不覆盖现有配置）-----------
DAEMON_JSON=/etc/docker/daemon.json
CONF=/opt/kata/share/defaults/kata-containers/configuration.toml
python3 - "$DAEMON_JSON" "$CONF" <<'PY'
import json, sys, os
path, conf = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f) or {}
data.setdefault("runtimes", {})["kata"] = {
    "runtimeType": "io.containerd.kata.v2",
    "options": {"ConfigPath": conf},
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f">> 已在 {path} 注册 runtime 'kata'")
PY

echo ">> 重启 dockerd 使 runtime 生效"
systemctl restart docker

# ---- 验证 ---------------------------------------------------------------------
echo ">> 验证："
docker info 2>/dev/null | grep -i runtime || true
echo ">> 试跑一个 Kata 容器（应输出 Hello）："
docker run --rm --runtime kata hello-world 2>&1 | grep -i hello \
  && echo ">> Kata 工作正常" \
  || echo ">> 警告: Kata 试跑失败，请查看上方 docker info 与 kata-runtime kata-check 输出"

cat <<'EOF'
>> 完成。之后 CE 容器用 runtime:kata 即跑在轻量 VM 里：
     docker compose up -d ce
   确认它确实进了 VM：
     docker exec ce-app uname -r        # 内核版本应是 Kata guest 内核，≠ 宿主机
EOF
