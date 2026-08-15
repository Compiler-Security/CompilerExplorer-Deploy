# syntax=docker/dockerfile:1
# Kata 备选路径：镜像只含 CE，工具链由 Compose 只读挂载。

FROM node:22-bookworm AS builder

ARG CE_REF=gh-18904

WORKDIR /ce
RUN git clone --depth 1 --branch "${CE_REF}" \
      https://github.com/compiler-explorer/compiler-explorer.git .

COPY --chmod=0755 scripts/apply-ce-patches.sh /tmp/apply-ce-patches.sh
COPY vm/patches/ /tmp/ce-patches/
RUN /tmp/apply-ce-patches.sh /ce /tmp/ce-patches

# 运行镜像不保留 .git，预先生成 dist 版本元数据。
RUN git rev-parse HEAD > git_hash \
 && printf '%s\n' "${CE_REF}" > release_build

RUN npm ci --no-audit --no-fund
RUN npm run webpack && npm run ts-compile

FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    TMPDIR=/tmp

WORKDIR /ce

# CE 的 C++ 默认配置会调用 objdump/c++filt；CFG 等功能需要 python3。
RUN apt-get update \
 && apt-get install -y --no-install-recommends binutils python3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /ce /ce
RUN npm prune --omit=dev \
 && npm cache clean --force \
 && rm -rf .git

RUN mkdir -p /opt/compiler-explorer

# uid/gid 与 Compose 一致。
RUN groupadd --system --gid 10001 ce \
 && useradd --system --uid 10001 --gid ce --home /ce ce \
 && mkdir -p /tmp /ce/lib/storage/data /ce/out/compiler-cache \
 && chown -R ce:ce /ce /tmp

USER ce

EXPOSE 10240

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:10240/healthcheck').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "./out/dist/app.js", \
     "--dist", \
     "--static", "./out/webpack/static", \
     "--host", "0.0.0.0", \
     "--port", "10240"]
