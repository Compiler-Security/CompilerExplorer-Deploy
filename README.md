# 内网自托管 CompilerExplorer（Clang/LLVM + GCC + 自研 MLIR）

一键 Docker 部署的 CompilerExplorer，内置可独立更新的工具链：

- **Clang/LLVM**（官方预编译，最新版；**全后端通用** —— 同一份 clang 加 `--target=riscv64-linux-gnu` 即可交叉 RISC-V）
- **GCC x86_64 原生 + GCC riscv64 交叉**（prepkg 预编译，GCC 最新，glibc 2.17 基线可在容器内运行）
- **Clang riscv64 交叉**（复用上面的 clang 二进制 + `--target`，无需单独下载）
- **自研 MLIR**（你们 Jenkins 每次提交 build，自动发布生效）

实例面向内网，**不加认证、不做 TLS**，但按公网标准加固。

## 隔离模型：Kata VM

CE 容器用 **`runtime: kata`** 跑在一个轻量级 **VM** 里（[Kata Containers](https://katacontainers.io/)，
Docker 的 VM 版 OCI 运行时），而不是共享宿主机内核的普通 cgroup 容器。

- **hypervisor 硬边界**：用户编译/运行的代码在一个独立内核的 VM 里，逃逸需打穿 QEMU/虚拟化层——
  比容器/nsjail 高一个量级。共享 / 多租户机器上，**别的租户完全不受影响**。
- **共享宿主机零改动**：不需要在宿主机上配 cgroup、放开 userns/AppArmor——这些隔离都在 VM 内。
- 因为 VM 已经是边界，**容器内不再需要 nsjail**，容器按最小权限收紧（非 root + 只读根 + drop ALL caps）。
- 也因此**开放「在线运行」是安全的**（用户程序只跑在 VM 里）：把 `config/c++.local.properties` 的
  `supportsExecute=false` 改 true 再 `docker compose restart ce` 即可。

> 前提：部署机有 `/dev/kvm`（硬件虚拟化）。Docker **不自带** Kata，需在宿主机装一次并注册进 dockerd
> ——用 `scripts/setup-kata.sh`。

## 架构

```
共享宿主机
 ├─ <CE_COMPILERS_ROOT>/              # 工具链根（只读挂进容器; 路径在 .env 配, 示例 /srv/ce/compilers）
 │    ├─ clang-<date>/  ← clang-latest (符号链接)
 │    ├─ gcc-<triple>-<date>/ ← gcc-latest / gcc-riscv-latest (符号链接)
 │    └─ mlir-custom.<build#>/ ← mlir-custom (符号链接)
 │
 ├─ docker compose
 │    └─ ce  ── runtime:kata ──► 轻量 VM（独立内核）
 │              └─ CE (node, 非 root, 只读根, drop ALL caps)
 │
 └─ 外部已有 nginx ── 反代到 127.0.0.1:10240（配置参考 nginx/ce.conf）
```

工具链走**宿主机目录 + 只读挂载 + 符号链接**，因此**更新任何工具链都不需要重建镜像**，
只需替换目录 / 拨链接 + `docker compose restart ce`。

> **工具链根路径不写死**：由仓库根 `.env` 的 `CE_COMPILERS_ROOT` 决定（docker-compose 与脚本都读它）。
> 容器内固定挂在 `/opt/compiler-explorer`（被 CE config 引用，勿改），只有宿主机侧路径可换。

> nginx 不进 Docker——用你们外部已有的部署，把 `nginx/ce.conf` 丢进其 `conf.d/` 即可。
> CE 只绑定宿主机回环 `127.0.0.1:10240`，对外只经 nginx 暴露。

## 首次部署

```bash
# 0. 装 Kata 并注册进 dockerd（一次性，root）。前提是宿主机有 /dev/kvm。
sudo scripts/setup-kata.sh

# 1. 配置工具链根路径（只需一次）
cp .env.example .env
#    编辑 .env，把 CE_COMPILERS_ROOT 改成你实际放置工具链的目录

# 2. 准备工具链目录（至少各放一份，并建好符号链接）
mkdir -p "$(grep -E '^CE_COMPILERS_ROOT=' .env | cut -d= -f2)"
#   推荐直接用脚本自动下载 Clang 与两种 GCC（默认源：llvm-project 官方 release + prepkg）：
scripts/update-clang-gcc.sh all        # 或分开: clang / gcc / gcc-riscv
#   - MLIR: 你们 Jenkins build 产物解压为 mlir-custom.<id>，ln -s 指向 mlir-custom
#   （想换成内部镜像源：用 CLANG_TARBALL_URL / GCC_TARBALL_URL / GCC_RISCV_TARBALL_URL 覆盖）

# 3. 构建并启动
docker compose build ce
docker compose up -d

# 4. 让外部 nginx 反代到 127.0.0.1:10240
#    把 nginx/ce.conf 复制到其 conf.d/（改 server_name），然后 nginx -s reload

# 5. 验证
curl http://127.0.0.1:10240/api/compilers   # 直连 CE（应列出 clang/gcc/mlir-opt）
docker exec ce-app uname -r                # 内核版本应是 Kata guest 内核，≠ 宿主机
docker compose logs -f ce
```

浏览器访问 `http://<服务器IP>/`，左侧选语言（C++ 或 MLIR）与编译器即可。

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
| `c++.local.properties` | 登记 Clang/GCC（`--gcc-toolchain`、demangler、Intel asm、riscv 交叉）、`supportsExecute` 开关 |
| `mlir.local.properties` | 登记自研 `mlir-opt` / `mlir-translate`，可加默认 pass |
| `compiler-explorer.local.properties` | 超时 / 并发 / 输出上限 / 危险 flag 黑名单 |
| `execution.local.properties` | 沙箱开关（Kata 下为 none，不用 nsjail） |

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

- **隔离 = Kata VM**：CE 跑在独立内核的轻量 VM，hypervisor 硬边界；共享机上别的租户不受影响。
- **容器最小权限**：非 root、`read_only` 根文件系统、`cap_drop ALL`、`no-new-privileges`、
  `/tmp` 为 `noexec` tmpfs、`pids_limit` 挡 fork 炸弹。容器内**无 nsjail、无 SYS_ADMIN、不共享宿主机 cgroup**。
- 外部 nginx（用 `nginx/ce.conf`）：安全响应头（nosniff / frame / CSP / Referrer-Policy 等）、
  `limit_req` 限流、`client_max_body_size 16m`；CE 只绑回环 `127.0.0.1:10240`，不直接对内网开放。
- 危险编译选项黑名单：`optionsForbiddenRe=--plugin|-fplugin|--wrapper`。
- **供应链完整性**：`update-clang-gcc.sh` 每次实际下载后核对 SHA256。在 `.env` 钉住
  `LLVM_SHA256` / `GCC_SHA256` / `GCC_RISCV_SHA256` 即强制比对、不符即中止；
  LLVM 包还会在有 `gpg` 时用官方 `.sig` 验签。prepkg 不发校验文件，只能靠钉哈希。
  `setup-kata.sh` 同样支持 `KATA_SHA256` 钉值。
- 镜像基于固定版本基底构建；建议纳入常规镜像/依赖漏洞扫描。

## 故障排查

- **`runtime: kata` 报错 / 起不来**：Kata 没装好或没注册。跑 `docker info | grep -i runtime` 看有没有
  `kata`；没有就重跑 `sudo scripts/setup-kata.sh`。再确认 `/dev/kvm` 存在。
- **想确认 CE 真在 VM 里**：`docker exec ce-app uname -r` 的内核版本应是 Kata guest 内核，与宿主机不同。
- **目标机开了 SELinux（Enforcing）**：容器读不到挂载的配置/工具链（日志报 Permission denied）。
  给 `docker-compose.yml` 里所有 bind mount 追加 `,z`（如 `:ro,z`），
  或执行 `sudo semanage fcontext -a -t container_file_t "<CE_COMPILERS_ROOT>(/.*)?" && sudo restorecon -R <CE_COMPILERS_ROOT>`。
  （两个更新脚本里已内置受保护的 `chcon`，在 Enforcing 机器上会自动给新工具链目录打标签。）
- **某编译器不出现在下拉框**：`docker compose logs ce | grep -i <名字>`；
  多为 `exe` 路径不对或符号链接断。确认宿主机 `<CE_COMPILERS_ROOT>/*-latest` 指向有效目录。
- **编译报找不到 libstdc++/启动文件**：检查 `c++.local.properties` 的
  `--gcc-toolchain=/opt/compiler-explorer/gcc-latest` 是否指向有效 GCC。
- **RISC-V 交叉编译找不到 C 库头文件**：在 `clangriscv` 那条补 `--sysroot=<gcc-riscv-latest>/riscv64-linux-gnu/sysroot`
  （确切路径以实际解压为准，见 `c++.local.properties` 注释）。
- **MLIR fork 起不来**：多半缺运行库 → 设 `compiler.myopt.ldPath`（见上）。
- **改配置不生效**：确认改的是 `config/*.local.properties`，且已 `docker compose restart ce`。
