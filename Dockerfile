# syntax=docker/dockerfile:1
# =============================================================================
# CompilerExplorer 自建镜像
#   隔离由 Kata VM（hypervisor 边界）提供，容器内不再需要 nsjail，
#   也不需要 SYS_ADMIN / 共享 cgroup —— 容器按最小权限收紧。
#   编译器不进镜像 —— 通过 compose 把宿主机工具链根只读挂载到 /opt/compiler-explorer。
#
# 构建：  docker compose build ce
# 更新 CE：修改下方 CE_REF（或 scripts/update-ce.sh），重新 build。
# =============================================================================

# ---- 构建阶段：装依赖 + 构建前端/后端 ---------------------------------------
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

# ---- 运行阶段：只留生产依赖，非 root ----------------------------------------
FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    TMPDIR=/tmp

WORKDIR /ce

# 拷贝整个构建产物树，再剔除 dev 依赖，得到可运行且相对精简的镜像。
COPY --from=builder /ce /ce
RUN npm prune --omit=dev \
 && npm cache clean --force

# /opt/compiler-explorer 是工具链的挂载目标（compose 只读挂载填充），先建空目录占位。
RUN mkdir -p /opt/compiler-explorer

# 非 root 运行（uid/gid 与 compose 中 user: 保持一致）
RUN groupadd --system --gid 10001 ce \
 && useradd --system --uid 10001 --gid ce --home /ce ce \
 && mkdir -p /tmp \
 && chown -R ce:ce /ce /tmp

USER ce

EXPOSE 10240

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:10240/healthcheck').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# 监听 0.0.0.0：对外只经外部 nginx 反代（compose 只发布到 ${CE_BIND_ADDR:-127.0.0.1}）。
CMD ["node", "./out/dist/app.js", \
     "--static", "./out/webpack/static", \
     "--host", "0.0.0.0", \
     "--port", "10240"]
