#!/usr/bin/env bash
# 将仓库中的 CE local properties 链接进 checkout；可在每次 ce.service 启动前重复执行。
set -euo pipefail

CE_HOME="${1:-/opt/ce}"
REPO_SRC="${2:-/mnt/ce-repo}"
CONFIG_SRC="${REPO_SRC}/config"
CONFIG_DST="${CE_HOME}/etc/config"

[[ -d "${CONFIG_SRC}" ]] \
  || { echo "错误: CE 配置源目录不存在: ${CONFIG_SRC}" >&2; exit 1; }
[[ -d "${CONFIG_DST}" ]] \
  || { echo "错误: CE 配置目标目录不存在: ${CONFIG_DST}" >&2; exit 1; }

shopt -s nullglob
config_files=("${CONFIG_SRC}"/*.local.properties)
((${#config_files[@]} > 0)) \
  || { echo "错误: ${CONFIG_SRC} 中没有 *.local.properties。" >&2; exit 1; }

# 删除只由本部署管理、但源文件已经移除的旧链接。
for target in "${CONFIG_DST}"/*.local.properties; do
  [[ -L "${target}" ]] || continue
  source_path="$(readlink "${target}")"
  if [[ "${source_path}" == "${CONFIG_SRC}/"* && ! -e "${source_path}" ]]; then
    rm -f -- "${target}"
  fi
done

for source_path in "${config_files[@]}"; do
  filename="${source_path##*/}"
  [[ "${filename}" =~ ^[A-Za-z0-9_+.-]+\.local\.properties$ ]] \
    || { echo "错误: CE 配置文件名不安全: ${filename}" >&2; exit 1; }
  ln -sfn -- "${source_path}" "${CONFIG_DST}/${filename}"
done

echo ">> 已同步 ${#config_files[@]} 个 CE local properties"
