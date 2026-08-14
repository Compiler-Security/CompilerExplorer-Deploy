# 内网自托管 CompilerExplorer（Clang/LLVM + GCC + 自研 MLIR）

一键 Docker 部署的 CompilerExplorer，内置三种可独立更新的工具链：

- **Clang/LLVM**（官方预编译，最新版）
- **GCC**（官方预编译，最新版）
- **自研 MLIR**（你们 Jenkins 每次提交 build，自动发布生效）

实例面向内网，**不加认证、不做 TLS**，但其余全部按公网标准加固
（容器最严隔离 + 只编译不运行 + 安全响应头 + 限流 + 危险 flag 黑名单）。

## 架构

```
宿主机
 ├─ /srv/ce/compilers/                # 工具链根（只读挂进容器）
 │    ├─ clang-<date>/  ← clang-latest (符号链接)
 │    ├─ gcc-<date>/    ← gcc-latest   (符号链接)
 │    └─ mlir-custom.<build#>/ ← mlir-custom (符号链接)
 │
 ├─ docker compose
 │    └─ ce  (node, 非 root, 只读根, drop ALL caps) → 127.0.0.1:10240
 │
 └─ 外部已有 nginx ── 反代到 127.0.0.1:10240（配置参考 nginx/ce.conf）
```

工具链走**宿主机目录 + 只读挂载 + 符号链接**，因此**更新任何工具链都不需要重建镜像**，
只需替换目录 / 拨链接 + `docker compose restart ce`。

> nginx 不进 Docker——用你们外部已有的部署，把 `nginx/ce.conf` 丢进其 `conf.d/` 即可。
> CE 只绑定宿主机回环 `127.0.0.1:10240`，对外只经 nginx 暴露。

## 首次部署

```bash
# 1. 准备工具链目录（至少各放一份，并建好符号链接）
sudo mkdir -p /srv/ce/compilers
#   - Clang/LLVM: 解压官方 tarball 为 clang-<date>，ln -s 指向 clang-latest
#   - GCC:        解压为 gcc-<date>，ln -s 指向 gcc-latest
#   - MLIR:       你们 Jenkins build 产物解压为 mlir-custom.<id>，ln -s 指向 mlir-custom
#   也可直接用 scripts/update-clang-gcc.sh 自动下载 Clang。

# 2. 构建并启动
docker compose build ce
docker compose up -d

# 3. 让外部 nginx 反代到 127.0.0.1:10240
#    把 nginx/ce.conf 复制到其 conf.d/（改 server_name），然后 nginx -s reload

# 4. 验证
curl http://127.0.0.1:10240/api/compilers   # 直连 CE（应列出 clang/gcc/mlir-opt）
docker compose logs -f ce
```

浏览器访问 `http://<服务器IP>/`，左侧选语言（C++ 或 MLIR）与编译器即可。

## 三套更新流程

| 对象 | 触发 | 命令 | 重建镜像 |
|---|---|---|---|
| **MLIR（自研）** | 每次提交 | Jenkins 调 `scripts/deploy-mlir.sh <产物目录> <build#>` | 否 |
| **Clang/GCC** | 出新版 | `scripts/update-clang-gcc.sh {clang\|gcc\|all}` | 否 |
| **CE 本体** | 上游新 release | `scripts/update-ce.sh gh-<tag>` | 是 |

### 接 Jenkins（MLIR 自动发布）

在你们**已有的 MLIR Jenkins job** 末尾加一个 deploy 阶段：

```groovy
stage('deploy to CE') {
  steps {
    sh '/srv/ce/ssct-compiler-explorer/scripts/deploy-mlir.sh "$WORKSPACE/build/install" "$BUILD_NUMBER"'
  }
}
```

脚本会 rsync 产物到 `mlir-custom.<build#>` → 原子切换 `mlir-custom` 链接 → `docker compose restart ce`，并保留最近 3 个旧版本可回滚。

**不需要为 CE 部署单独建 Jenkins job**：Clang/GCC 更新手动跑脚本（或挂低频定时），
CE 本体手动跑 `update-ce.sh`（或低频定时）即可。

## 配置

所有 CE 覆盖配置在 `config/*.local.properties`，**改完 `docker compose restart ce` 即生效，无需重建镜像**：

| 文件 | 作用 |
|---|---|
| `c++.local.properties` | 登记 Clang/GCC（`--gcc-toolchain`、demangler、Intel asm） |
| `mlir.local.properties` | 登记自研 `mlir-opt` / `mlir-translate`，可加默认 pass |
| `compiler-explorer.local.properties` | 超时 / 并发 / 输出上限 / 危险 flag 黑名单 |
| `execution.local.properties` | 沙箱开关（当前策略 A：不执行用户程序） |

### 给 MLIR 设默认 pass

`mlir.local.properties` 里取消注释并按需修改：

```properties
compiler.myopt.options=--mlir-print-ir-after-all
```

### 自研工具链库路径

若 fork 的运行库不在系统路径，在 `mlir.local.properties` 加：

```properties
compiler.myopt.ldPath=/opt/compiler-explorer/mlir-custom/lib
```

## 安全说明（按公网标准，未开认证/TLS）

- **策略 A：只编译 / 看产物，不执行用户程序**（C++ 与 MLIR 均 `supportsExecute=false`）。
- CE 容器：`read_only` 根文件系统、`cap_drop ALL`、`no-new-privileges`、非 root、`/tmp` 为 `noexec` tmpfs。
- 外部 nginx（用 `nginx/ce.conf`）：安全响应头（nosniff / frame / CSP / Referrer-Policy 等）、
  `limit_req` 限流、`client_max_body_size 16m`；CE 只绑回环 `127.0.0.1:10240`，不直接对内网开放。
- 危险编译选项黑名单：`optionsForbiddenRe=--plugin|-fplugin|--wrapper`。
- 镜像基于固定版本基底构建；建议纳入常规镜像/依赖漏洞扫描。

**若日后需要在线运行编译产物**（策略 B）：需启用 nsjail 沙箱（CE fork 版），并给容器放权
（SYS_ADMIN + 放开 seccomp/apparmor + cgroup），详见 `config/execution.local.properties` 注释。
若安全部门日后要求 HTTPS，只需在 nginx 加证书，架构不变。

## 故障排查

- **目标机开了 SELinux（Enforcing）**：容器读不到挂载的配置/工具链（日志报 Permission denied）。
  给 `docker-compose.yml` 里所有 bind mount 追加 `,z`（如 `:ro,z`），
  或执行 `sudo semanage fcontext -a -t container_file_t "/srv/ce/compilers(/.*)?" && sudo restorecon -R /srv/ce/compilers`。
  （两个更新脚本里已内置受保护的 `chcon`，在 Enforcing 机器上会自动给新工具链目录打标签。）
- **某编译器不出现在下拉框**：`docker compose logs ce | grep -i <名字>`；
  多为 `exe` 路径不对或符号链接断。确认宿主机 `/srv/ce/compilers/*-latest` 指向有效目录。
- **编译报找不到 libstdc++/启动文件**：检查 `c++.local.properties` 的
  `--gcc-toolchain=/opt/compiler-explorer/gcc-latest` 是否指向有效 GCC。
- **MLIR fork 起不来**：多半缺运行库 → 设 `compiler.myopt.ldPath`（见上）。
- **CE 启动失败且怀疑只读根**：看日志里报的只读写路径，给它加一个 tmpfs；
  或临时把 `ce` 服务的 `read_only: true` 去掉定位后再加回。
- **改配置不生效**：确认改的是 `config/*.local.properties`，且已 `docker compose restart ce`。
