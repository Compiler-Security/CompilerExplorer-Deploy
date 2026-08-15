#!/usr/bin/env bash
# 安装 kata-static 并注册为 Docker runtime `kata`；须以 root 运行。
# 可用 KATA_VERSION / KATA_SHA256 固定版本与哈希。
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
[[ -z "${KATA_SHA256}" || "${KATA_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: KATA_SHA256 必须是 64 位十六进制。" >&2; exit 2; }
KATA_SHA256="${KATA_SHA256,,}"
WORK="$(mktemp -d)"
STAGED_KATA=""
OLD_KATA=""
INSTALLED_KATA_THIS_RUN=0
KATA_VALIDATED=0
cleanup() {
  # 新版本未通过 kata-check 时恢复旧版本。
  if [[ "${INSTALLED_KATA_THIS_RUN}" == "1" && "${KATA_VALIDATED}" != "1" ]]; then
    rm -rf -- /opt/kata
  fi
  if [[ -n "${OLD_KATA}" && ( -e "${OLD_KATA}" || -L "${OLD_KATA}" ) ]]; then
    if [[ ! -e /opt/kata && ! -L /opt/kata ]]; then
      if mv "${OLD_KATA}" /opt/kata 2>/dev/null; then
        OLD_KATA=""
      else
        echo ">> 警告: 恢复旧 Kata 失败，备份保留在 ${OLD_KATA}" >&2
      fi
    else
      rm -rf -- "${OLD_KATA}"
      OLD_KATA=""
    fi
  fi
  [[ -z "${STAGED_KATA}" ]] || rm -rf -- "${STAGED_KATA}"
  rm -rf -- "${WORK}"
}
trap cleanup EXIT

if [[ -z "${KATA_VERSION}" ]]; then
  echo ">> 查询 kata-containers 最新 release ..."
  RELEASE_API="https://api.github.com/repos/kata-containers/kata-containers/releases/latest"
else
  [[ "${KATA_VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || { echo "错误: KATA_VERSION 含非法字符。" >&2; exit 2; }
  RELEASE_API="https://api.github.com/repos/kata-containers/kata-containers/releases/tags/${KATA_VERSION}"
fi
json="$(curl -fsSL --retry 3 "${RELEASE_API}")"
if [[ -z "${KATA_VERSION}" ]]; then
  KATA_VERSION="$(printf '%s\n' "${json}" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  KATA_VERSION="${KATA_VERSION%%$'\n'*}"
fi
[[ -n "${KATA_VERSION}" ]] || { echo "错误: 解析不到 Kata 版本；请 KATA_VERSION=... 指定"; exit 1; }
[[ "${KATA_VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || { echo "错误: Kata release tag 含非法字符。" >&2; exit 2; }
ASSET="kata-static-${KATA_VERSION}-amd64.tar.zst"
URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${ASSET}"
echo ">> 目标版本 ${KATA_VERSION}: ${URL}"

command -v python3 >/dev/null 2>&1 \
  || { echo "错误: 缺少 python3（用于解析 release 元数据并安全合并 daemon.json）。" >&2; exit 1; }
mapfile -t ASSET_META < <(printf '%s' "${json}" | python3 -c '
import json, sys
asset_name = sys.argv[1]
for asset in json.load(sys.stdin).get("assets", []):
    if asset.get("name") == asset_name:
        digest = asset.get("digest") or ""
        print(digest[7:] if digest.startswith("sha256:") else digest)
        print(asset.get("browser_download_url") or "")
        break
' "${ASSET}")
OFFICIAL_SHA256="${ASSET_META[0]:-}"
OFFICIAL_URL="${ASSET_META[1]:-}"
[[ -n "${OFFICIAL_URL}" ]] \
  || { echo "错误: release ${KATA_VERSION} 中找不到资产 ${ASSET}。" >&2; exit 1; }
URL="${OFFICIAL_URL}"
[[ -z "${OFFICIAL_SHA256}" || "${OFFICIAL_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] \
  || { echo "错误: release API 返回了无效 digest。" >&2; exit 1; }
OFFICIAL_SHA256="${OFFICIAL_SHA256,,}"
EXPECTED_SHA256="${KATA_SHA256:-${OFFICIAL_SHA256}}"
[[ -n "${EXPECTED_SHA256}" ]] \
  || { echo "错误: release API 未提供 digest；请核对官方后用 KATA_SHA256 固定哈希。" >&2; exit 1; }

INSTALLED_KATA_INFO=""
if [[ -x /opt/kata/bin/kata-runtime ]]; then
  INSTALLED_KATA_INFO="$(/opt/kata/bin/kata-runtime --version 2>/dev/null || true)"
fi
if grep -Fq "${KATA_VERSION}" <<< "${INSTALLED_KATA_INFO}"; then
  echo ">> Kata ${KATA_VERSION} 已安装，跳过下载/解压"
else
  echo ">> 下载并解压 kata-static ..."
  curl -fSL --retry 3 -o "${WORK}/kata.tar.zst" "${URL}"

  actual="$(sha256sum "${WORK}/kata.tar.zst" | awk '{print $1}')"
  [[ "${actual}" == "${EXPECTED_SHA256}" ]] \
    || { echo "错误: SHA256 不匹配！期望 ${EXPECTED_SHA256} 实际 ${actual}。已中止。" >&2; exit 1; }
  echo ">> SHA256 校验通过"

  command -v zstd >/dev/null 2>&1 || {
    echo ">> 安装 zstd（解压 .tar.zst 需要）"
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y zstd
    elif command -v dnf >/dev/null 2>&1; then dnf install -y zstd
    else echo "请手动安装 zstd"; exit 1; fi
  }
  # 在 /opt 同一文件系统内分阶段解压并切换。
  STAGED_KATA="$(mktemp -d /opt/.kata.new.XXXXXX)"
  tar --zstd -xf "${WORK}/kata.tar.zst" -C "${STAGED_KATA}" --strip-components=2
  [[ -x "${STAGED_KATA}/bin/kata-runtime" \
     && -x "${STAGED_KATA}/bin/containerd-shim-kata-v2" \
     && -f "${STAGED_KATA}/share/defaults/kata-containers/configuration.toml" ]] \
    || { echo "错误: Kata 资产结构不完整，拒绝安装。" >&2; exit 1; }

  OLD_KATA="$(mktemp -d /opt/.kata.old.XXXXXX)"
  rmdir "${OLD_KATA}"
  if [[ -e /opt/kata || -L /opt/kata ]]; then
    mv /opt/kata "${OLD_KATA}"
  else
    OLD_KATA=""
  fi
  mv "${STAGED_KATA}" /opt/kata
  STAGED_KATA=""
  INSTALLED_KATA_THIS_RUN=1
  echo ">> 已解压到 /opt/kata"
fi

[[ -x /opt/kata/bin/kata-runtime \
   && -x /opt/kata/bin/containerd-shim-kata-v2 \
   && -f /opt/kata/share/defaults/kata-containers/configuration.toml ]] \
  || { echo "错误: /opt/kata 安装不完整。" >&2; exit 1; }

echo ">> 运行 kata-runtime kata-check"
/opt/kata/bin/kata-runtime kata-check
KATA_VALIDATED=1
[[ -z "${OLD_KATA}" ]] || rm -rf -- "${OLD_KATA}"
OLD_KATA=""

mkdir -p /usr/local/bin
ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

# 合并 daemon.json，不覆盖其它设置。
DAEMON_JSON=/etc/docker/daemon.json
CONF=/opt/kata/share/defaults/kata-containers/configuration.toml
python3 - "$DAEMON_JSON" "$CONF" <<'PY'
import json, os, stat, sys
path, conf = sys.argv[1], sys.argv[2]
data = {}
mode = 0o644
if os.path.exists(path):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    with open(path) as f:
        data = json.load(f) or {}
data.setdefault("runtimes", {})["kata"] = {
    "runtimeType": "io.containerd.kata.v2",
    "options": {"ConfigPath": conf},
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print(f">> 已在 {path} 注册 runtime 'kata'")
PY

echo ">> 重启 dockerd 使 runtime 生效"
systemctl restart docker

echo ">> 验证："
docker info 2>/dev/null | grep -i runtime || true
echo ">> 试跑一个 Kata 容器（应输出 Hello）："
docker run --rm --runtime kata hello-world 2>&1 | grep -i hello \
  && echo ">> Kata 工作正常" \
  || echo ">> 警告: Kata 试跑失败，请查看上方 docker info 与 kata-runtime kata-check 输出"

cat <<'EOF'
>> 完成。之后 CE 容器用 runtime:kata 即跑在轻量 VM 里：
     docker compose -f compose.kata.yaml up -d ce
   确认它确实进了 VM：
     docker exec ce-app uname -r        # 内核版本应是 Kata guest 内核，≠ 宿主机
EOF
