# 内网自托管 CompilerExplorer（Clang/LLVM + GCC + 自研 MLIR）

一键 Docker 部署的 CompilerExplorer，内置可独立更新的工具链：

- **Clang/LLVM**（官方预编译，最新版；**全后端通用** —— 同一份 clang 加 `--target=riscv64-linux-gnu` 即可交叉 RISC-V）
- **GCC x86_64 原生 + GCC riscv64 交叉**（prepkg 预编译，GCC 最新，glibc 2.17 基线可在容器内运行）
- **Clang riscv64 交叉**（复用上面的 clang 二进制 + `--target`，无需单独下载）
- **自研 MLIR**（你们 Jenkins 每次提交 build，自动发布生效）

实例面向内网，**不加认证、不做 TLS**，但其余全部按公网标准加固：
**nsjail 沙箱**包裹编译器/工具执行（CE fork 版），用户程序沙箱配置已就绪；
外部 nginx 做安全响应头 + 限流；CE 只绑回环不直接对内网开放；危险 flag 黑名单。
当前默认**只编译 / 看产物，不在线运行**（`supportsExecute=false`），日后改 true 即开。

## 架构

```
宿主机
 ├─ <CE_COMPILERS_ROOT>/              # 工具链根（只读挂进容器; 路径在 .env 配, 示例 /srv/ce/compilers）
 │    ├─ clang-<date>/  ← clang-latest (符号链接)
 │    ├─ gcc-<triple>-<date>/ ← gcc-latest / gcc-riscv-latest (符号链接)
 │    └─ mlir-custom.<build#>/ ← mlir-custom (符号链接)
 │
 ├─ docker compose
 │    └─ ce  (node, 非 root, nsjail 沙箱, 只读根) → 127.0.0.1:10240
 │         # nsjail 需容器放权: SYS_ADMIN/SYS_PTRACE + 共享宿主机 cgroup
 │
 └─ 外部已有 nginx ── 反代到 127.0.0.1:10240（配置参考 nginx/ce.conf）
```

工具链走**宿主机目录 + 只读挂载 + 符号链接**，因此**更新任何工具链都不需要重建镜像**，
只需替换目录 / 拨链接 + `docker compose restart ce`。

> **工具链根路径不写死**：由仓库根 `.env` 的 `CE_COMPILERS_ROOT` 决定（docker-compose 与脚本都读它）。
> 容器内固定挂在 `/opt/compiler-explorer`（被 nsjail cfg 与 CE config 引用，勿改），只有宿主机侧路径可换。

> nginx 不进 Docker——用你们外部已有的部署，把 `nginx/ce.conf` 丢进其 `conf.d/` 即可。
> CE 只绑定宿主机回环 `127.0.0.1:10240`，对外只经 nginx 暴露。

## 首次部署

```bash
# 0. 配置工具链根路径（只需一次）
cp .env.example .env
#    编辑 .env，把 CE_COMPILERS_ROOT 改成你实际放置工具链的目录

# 1. 准备工具链目录（至少各放一份，并建好符号链接）
mkdir -p "$(grep -E '^CE_COMPILERS_ROOT=' .env | cut -d= -f2)"
#   推荐直接用脚本自动下载 Clang 与两种 GCC（默认源：llvm-project 官方 release + prepkg）：
scripts/update-clang-gcc.sh all        # 或分开: clang / gcc / gcc-riscv
#   - MLIR: 你们 Jenkins build 产物解压为 mlir-custom.<id>，ln -s 指向 mlir-custom
#   （想换成内部镜像源：用 CLANG_TARBALL_URL / GCC_TARBALL_URL / GCC_RISCV_TARBALL_URL 覆盖）

# 2. nsjail 前置（一次性，root）：建 ce-compile/ce-sandbox cgroup + 放开 userns
sudo scripts/setup-nsjail-cgroups.sh --install-systemd   # 装开机自启，重启不丢

# 3. 构建并启动
docker compose build ce
docker compose up -d

# 4. 让外部 nginx 反代到 127.0.0.1:10240
#    把 nginx/ce.conf 复制到其 conf.d/（改 server_name），然后 nginx -s reload

# 5. 验证
curl http://127.0.0.1:10240/api/compilers   # 直连 CE（应列出 clang/gcc/mlir-opt）
docker compose logs -f ce
```

浏览器访问 `http://<服务器IP>/`，左侧选语言（C++ 或 MLIR）与编译器即可。

> **nsjail 依赖宿主机前置**：`setup-nsjail-cgroups.sh` 创建的两个 cgroup（`ce-compile`/`ce-sandbox`）
> 重启即失，所以脚本支持 `--install-systemd` 装一个 oneshot unit 持久化。
> 若漏了这步，CE 一编译就会报 `Launching child process failed`。

## 三套更新流程

| 对象 | 触发 | 命令 | 重建镜像 |
|---|---|---|---|
| **MLIR（自研）** | 每次提交 | Jenkins 调 `scripts/deploy-mlir.sh <产物目录> <build#>` | 否 |
| **Clang/GCC** | 出新版 | `scripts/update-clang-gcc.sh {clang\|gcc\|gcc-riscv\|all}` | 否 |
| **CE 本体** | 上游新 release | `scripts/update-ce.sh gh-<tag>` | 是 |

### 接 Jenkins（MLIR 自动发布）

在你们**已有的 MLIR Jenkins job** 末尾加一个 deploy 阶段：

```groovy
stage('deploy to CE') {
  steps {
    // 路径指向你部署机上的本仓库；脚本会自己读仓库根 .env 的 CE_COMPILERS_ROOT
    sh '/path/to/ssct-compiler-explorer/scripts/deploy-mlir.sh "$WORKSPACE/build/install" "$BUILD_NUMBER"'
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
| `execution.local.properties` | nsjail 沙箱开关（编译器 + 用户程序两份 cfg 路径） |

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

核心是 **nsjail 沙箱**（CE fork 版，`executionType=nsjail` + `sandboxType=nsjail`）：

- **编译器沙箱**（每次编译都进）：jail 内只读挂载 `/bin /lib /usr /opt/compiler-explorer`，
  cgroup 限制 1.25 GiB 内存 / 72 进程 / 单核 100%，`noexec` tmpfs `/tmp`，无网络。
- **用户程序沙箱**（仅当开放运行时用到）：更严（200 MiB / 14 进程 / 单核 50% / 无 `/bin`），
  当前 `supportsExecute=false` 未启用。
- 容器以非 root 运行、根文件系统只读、`/tmp` 为 tmpfs。
- 外部 nginx（用 `nginx/ce.conf`）：安全响应头（nosniff / frame / CSP / Referrer-Policy 等）、
  `limit_req` 限流、`client_max_body_size 16m`；CE 只绑回环 `127.0.0.1:10240`，不直接对内网开放。
- 危险编译选项黑名单：`optionsForbiddenRe=--plugin|-fplugin|--wrapper`。
- 镜像基于固定版本基底构建；建议纳入常规镜像/依赖漏洞扫描。

**权衡（要知道）**：nsjail 需要给容器放权（`SYS_ADMIN`/`SYS_PTRACE` + 放开 seccomp/apparmor +
共享宿主机 cgroup），所以**真正的隔离由 nsjail 提供，容器边界被有意放宽**——这与官方 godbolt 的
做法一致。若想在不放权的前提下隔离，可回头用纯容器方案（无 nsjail、不开放运行），见 git 历史首版。

**开放「在线运行」**：把 `config/c++.local.properties` 的 `supportsExecute=false` 改成 `true`，
再 `docker compose restart ce` 即可——nsjail 用户程序沙箱、宿主机 cgroup 都已就绪，无需其它改动。
若安全部门日后要求 HTTPS，只需在 nginx 加证书，架构不变。

## 故障排查

- **一编译就报 `Launching child process failed`**：nsjail 的 cgroup 没建好。
  确认宿主机跑过 `sudo scripts/setup-nsjail-cgroups.sh`（或 `ce-cgroups.service` 已 enable 且重启后仍在）：
  `ls -la /sys/fs/cgroup/ce-compile /sys/fs/cgroup/ce-sandbox`，且属主是 uid 10001。
  也可 `docker compose exec ce /usr/local/bin/nsjail --version` 确认二进制在。
- **nsjail mount 报 `No such file or directory`**：某个非可选 mount 源在容器里不存在。
  常见是 `/etc/localtime`（镜像已装 tzdata 兜底）；若是自定义路径，往
  `etc/nsjail/compilers-and-tools.cfg` 加对应 bind mount（见该 cfg 注释 / 官方 NsjailSandbox.md）。
- **怀疑容器放权/只读根导致 nsjail 失败**：临时把 `docker-compose.yml` 里 `read_only` 改 `false` 定位；
  仍不行就加 `privileged: true` 试（官方文档的兜底），定位后再收紧。
- **目标机开了 SELinux（Enforcing）**：容器读不到挂载的配置/工具链（日志报 Permission denied）。
  给 `docker-compose.yml` 里所有 bind mount 追加 `,z`（如 `:ro,z`），
  或执行 `sudo semanage fcontext -a -t container_file_t "<CE_COMPILERS_ROOT>(/.*)?" && sudo restorecon -R <CE_COMPILERS_ROOT>`。
  （两个更新脚本里已内置受保护的 `chcon`，在 Enforcing 机器上会自动给新工具链目录打标签。）
- **某编译器不出现在下拉框**：`docker compose logs ce | grep -i <名字>`；
  多为 `exe` 路径不对或符号链接断。确认宿主机 `<CE_COMPILERS_ROOT>/*-latest` 指向有效目录。
- **编译报找不到 libstdc++/启动文件**：检查 `c++.local.properties` 的
  `--gcc-toolchain=/opt/compiler-explorer/gcc-latest` 是否指向有效 GCC。
- **MLIR fork 起不来**：多半缺运行库 → 设 `compiler.myopt.ldPath`（见上）。
- **改配置不生效**：确认改的是 `config/*.local.properties`，且已 `docker compose restart ce`。
