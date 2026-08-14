# syntax=docker/dockerfile:1
# =============================================================================
# CompilerExplorer 自建镜像（含 nsjail 沙箱）
#   策略 B 底座：用 CE fork 的 nsjail 包裹编译器（executionType=nsjail），
#   用户程序沙箱（sandboxType=nsjail）配置已就绪，「在线运行」默认关闭
#   （c++.local.properties 里 supportsExecute=false），日后改 true + restart 即开。
#   编译器不进镜像 —— 由 compose 把宿主机 /srv/ce/compilers 只读挂载到
#   /opt/compiler-explorer；本镜像含 CE 应用 + nsjail 二进制。
#
# 构建：  docker compose build ce
# 更新 CE：修改下方 CE_REF（或 scripts/update-ce.sh），重新 build。
# =============================================================================

# ---- nsjail 构建阶段（CE fork, 分支 ce；勿用上游 google/nsjail）-------------
# 依赖与命令来自官方 NsjailSandbox.md 与该 fork 自带 Dockerfile。
FROM debian:bookworm-slim AS nsjail-build
RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf bison flex gcc g++ git ca-certificates \
      libprotobuf-dev libnl-route-3-dev libtool make pkg-config protobuf-compiler \
 && rm -rf /var/lib/apt/lists/*
# kafel 子模块必须一起拉（make 依赖它）。
RUN git clone --depth 1 --branch ce --recurse-submodules --shallow-submodules \
      https://github.com/compiler-explorer/nsjail.git /nsjail
WORKDIR /nsjail
RUN make

# ---- CE 构建阶段：装依赖 + 构建前端/后端 -------------------------------------
# 用完整的 bookworm（自带编译工具链），以便 npm ci 能编译原生扩展。
FROM node:22-bookworm AS builder

# CE 版本。用 gh-NNNNN 形式的 release tag 固定，保证可复现。
# 查看最新 tag: https://github.com/compiler-explorer/compiler-explorer/tags
ARG CE_REF=gh-18904

WORKDIR /ce
RUN git clone --depth 1 --branch "${CE_REF}" \
      https://github.com/compiler-explorer/compiler-explorer.git .

# 完整依赖（含 devDependencies：webpack / typescript 构建需要）
RUN npm ci --no-audit --no-fund

# 前端静态资源 -> out/webpack/static ; 后端 TS -> out/dist
RUN npm run webpack && npm run ts-compile

# ---- 运行阶段：只留生产依赖 + nsjail + 其运行库，非 root ---------------------
FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    TMPDIR=/tmp

WORKDIR /ce

# nsjail 运行时依赖（libprotobuf32 / libnl-route-3-200）。
# tzdata 提供 /etc/localtime —— compilers-and-tools.cfg 对它为非可选 bind mount，
# slim 镜像默认没有，缺了 nsjail 会报 "No such file or directory"。
RUN apt-get update && apt-get install -y --no-install-recommends \
      libprotobuf32 libnl-route-3-200 tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# nsjail 二进制（CE fork）。
COPY --from=nsjail-build /nsjail/nsjail /usr/local/bin/nsjail

# 拷贝整个构建产物树，再剔除 dev 依赖，得到可运行且相对精简的镜像。
COPY --from=builder /ce /ce
RUN npm prune --omit=dev \
 && npm cache clean --force

# /opt/compiler-explorer 是 cfg 里的非可选 mount 源；运行时由宿主机只读挂载填充，
# 这里先建空目录占位，保证挂载前路径存在。
RUN mkdir -p /opt/compiler-explorer

# 非 root 运行（uid/gid 与 compose 中 user:、宿主机 cgroup 属主保持一致）
RUN groupadd --system --gid 10001 ce \
 && useradd --system --uid 10001 --gid ce --home /ce ce \
 && mkdir -p /tmp \
 && chown -R ce:ce /ce /tmp

USER ce

EXPOSE 10240

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:10240/healthcheck').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# 监听 0.0.0.0：对外只经外部 nginx 反代（compose 只发布到 127.0.0.1）。
CMD ["node", "./out/dist/app.js", \
     "--static", "./out/webpack/static", \
     "--host", "0.0.0.0", \
     "--port", "10240"]
