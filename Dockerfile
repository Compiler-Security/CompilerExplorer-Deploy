# syntax=docker/dockerfile:1
# =============================================================================
# CompilerExplorer 自建镜像
#   策略 A：只编译 / 看产物，不执行用户程序；容器锁到最严。
#   编译器不进镜像 —— 通过 compose 把宿主机 /srv/ce/compilers 只读挂载到
#   /opt/compiler-explorer；本镜像只含 CE 应用本身。
#
# 构建：  docker compose build ce
# 更新 CE：修改下方 CE_REF（或在 scripts/update-ce.sh 里改），重新 build。
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

# 固定基底 digest 更利于漏洞扫描复现，按需取消注释并填实际 digest：
# FROM node:22-bookworm-slim@sha256:<digest>

ENV NODE_ENV=production \
    TMPDIR=/tmp

WORKDIR /ce

# 拷贝整个构建产物树，再剔除 dev 依赖，得到可运行且相对精简的镜像。
COPY --from=builder /ce /ce
RUN npm prune --omit=dev \
 && npm cache clean --force

# 非 root 运行（uid/gid 与 compose 中 user: 保持一致）
RUN groupadd --system --gid 10001 ce \
 && useradd --system --uid 10001 --gid ce --home /ce ce \
 && mkdir -p /tmp \
 && chown -R ce:ce /ce /tmp

USER ce

EXPOSE 10240

# CE 自带健康检查端点；用 node 发起（slim 镜像无 curl）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:10240/healthcheck').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# 监听容器内回环即可——由同网络的 nginx 反代对外。
CMD ["node", "./out/dist/app.js", \
     "--static", "./out/webpack/static", \
     "--host", "0.0.0.0", \
     "--port", "10240"]
