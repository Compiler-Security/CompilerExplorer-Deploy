# 内网自托管 CompilerExplorer（Clang/LLVM + GCC + 自研 MLIR）

一键 Docker 部署的 CompilerExplorer，内置可独立更新的工具链：

- **Clang/LLVM**（官方预编译，最新版；**全后端通用** —— 同一份 clang 加 `--target=riscv64-linux-gnu` 即可交叉 RISC-V）
- **GCC x86_64 原生 + GCC riscv64 交叉**（prepkg 预编译，GCC 最新，glibc 2.17 基线可在容器内运行）
- **Clang riscv64 交叉**（复用上面的 clang 二进制 + `--target`，无需单独下载）
- **自研 MLIR**（你们 Jenkins 每次提交 build，自动发布生效）

实例面向内网，**不加认证、不做 TLS**，但按公网标准加固。

## 隔离模型：QEMU/KVM VM（Docker 里起 VM）

CE 跑在一个 **QEMU/KVM VM** 里，而这个 VM 由一个 Docker 容器启动（`vm/` + `docker-compose.vm.yml`）。
用户编译/运行的代码在一个独立内核的 VM 中——**hypervisor 硬边界**，逃逸需打穿 QEMU/虚拟化层，
共享 / 多租户机器上别的租户完全不受影响。

- **共享宿主机零改动**：唯一暴露面是一个带 `/dev/kvm` 的 QEMU 容器；不动宿主机的 cgroup / userns / AppArmor。
- **VM 内是专用的**，所以 CE 容器用普通 docker(runc) + 最小权限即可，**不需要 nsjail**。
- 也因此**开放「在线运行」是安全的**（程序只跑在 VM 里）：改 `config/c++.local.properties` 的
  `supportsExecute=false` 为 true 再重启即可。

> 前提：部署机有 `/dev/kvm`（硬件虚拟化；若部署机本身是 VM 需开嵌套虚拟化）。

> **备选**：若有一台装了 [Kata Containers](https://katacontainers.io/) 的**专用机**，可以不套 QEMU，
> 直接给 `docker-compose.yml` 的 ce 服务加一行 `runtime: kata`，让 CE 容器本身跑在轻量 VM 里
> （宿主一次性装好用 `scripts/setup-kata.sh`）。本仓库主线用 QEMU-in-Docker，因为不要求宿主机装 Kata。

## 架构

```
共享宿主机
 ├─ <CE_COMPILERS_ROOT>/            # 工具链根（9p 只读共享进 VM; 路径在 .env 配, 示例 /srv/ce/compilers）
 │    ├─ clang-<date>/  ← clang-latest (符号链接)
 │    ├─ gcc-<triple>-<date>/ ← gcc-latest / gcc-riscv-latest (符号链接)
 │    └─ mlir-custom.<build#>/ ← mlir-custom (符号链接)
 │
 ├─ docker compose -f docker-compose.vm.yml
 │    └─ qemu 容器（--device /dev/kvm）
 │         └─ QEMU/KVM VM（默认 8C/8G，virtio disk + user-net）
 │              └─ VM 内: docker compose up ce   ← 跑的就是本仓库 docker-compose.yml + config/ + scripts/
 │
 └─ 外部已有 nginx ── 反代到 127.0.0.1:10240 →(QEMU hostfwd)→ VM 的 CE
```

工具链走**宿主机目录 + 9p 共享 + 符号链接**：**更新任何工具链都不需要重建镜像、也不用动 VM**——
Jenkins/脚本更新宿主机目录，经 9p 实时反映进 VM，只需让 VM 里的 CE 重启感知。

> **工具链根路径不写死**：由仓库根 `.env` 的 `CE_COMPILERS_ROOT` 决定（compose 与脚本都读它）。
> VM 内固定挂在 `/opt/compiler-explorer`（被 CE config 引用），只有宿主机侧路径可换。

> nginx 不进 Docker——用你们外部已有的部署，把 `nginx/ce.conf` 丢进其 `conf.d/` 即可。

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

# 2. 起 QEMU/KVM VM（首启：下载云镜像 + cloud-init 装配 + 在 VM 内构建 CE 镜像，较慢）
docker compose -f docker-compose.vm.yml build qemu
docker compose -f docker-compose.vm.yml up -d
docker compose -f docker-compose.vm.yml logs -f qemu   # 看 VM 串口日志 / cloud-init 进度

# 3. 让外部 nginx 反代到 127.0.0.1:10240
#    把 nginx/ce.conf 复制到其 conf.d/（改 server_name），然后 nginx -s reload

# 4. 验证
curl http://127.0.0.1:10240/api/compilers   # 经 nginx/hostfwd 到 VM 里的 CE（应列出 clang/gcc/mlir-opt）
```

浏览器访问 `http://<服务器IP>/`，左侧选语言（C++ 或 MLIR）与编译器即可。

**说明**
- VM 里跑的**就是本仓库这套**（`docker-compose.yml` + `config/` + `scripts/`），经 9p 只读共享进去，
  cloud-init 拷成可写副本（`/srv/ce-repo`）后 `docker compose up`。
- **改 CE 配置**才需要让 VM 重读：编辑宿主仓库后重建 VM（`docker compose -f docker-compose.vm.yml down -v && up -d`），
  或进 VM 里改 `/srv/ce-repo` 再 `docker compose restart ce`。
- VM 规格用 `VM_CPUS` / `VM_MEM_MB` / `VM_DISK_SIZE` 调（compose 环境变量）。
- 首启失败先看 `logs qemu`：没 `/dev/kvm` 会直接报错（绝不悄悄退化成软件模拟）。

## 三套更新流程

| 对象 | 触发 | 命令 | 重建镜像/VM |
|---|---|---|---|
| **MLIR（自研）** | 每次提交 | Jenkins 调 `scripts/deploy-mlir.sh <产物目录> <build#>`（更新宿主机目录，9p 实时进 VM） | 否 |
| **Clang/GCC** | 出新版 | `scripts/update-clang-gcc.sh {clang\|gcc\|gcc-riscv\|all}` | 否 |
| **CE 本体** | 上游新 release | 编辑宿主仓库配置/Dockerfile → 重建 VM（`down -v && up -d`） | 重建 VM |

> 工具链更新走宿主机目录 + 9p 共享，**不进 VM 镜像、不动 VM**；改 CE 配置/版本才重建 VM。
> 让 VM 里的 CE 感知新工具链：进 VM `docker compose restart ce`，或 `restart qemu`（VM 重启后 cloud-init
> 不会重跑，但容器 restart 会重读挂载的工具链）。

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

脚本会 rsync 产物到 `mlir-custom.<build#>` → 原子切换 `mlir-custom` 链接（经 9p 实时反映进 VM），并保留最近 3 个旧版本可回滚。

**不需要为 CE 部署单独建 Jenkins job**：Clang/GCC 更新手动跑脚本（或挂低频定时），CE 本体/配置更新重建 VM 即可。

## 配置

所有 CE 覆盖配置在 `config/*.local.properties`（在 VM 里经 `docker compose restart ce` 生效）：

| 文件 | 作用 |
|---|---|
| `c++.local.properties` | 登记 Clang/GCC（`--gcc-toolchain`、demangler、Intel asm、riscv 交叉）、`supportsExecute` 开关 |
| `mlir.local.properties` | 登记自研 `mlir-opt` / `mlir-translate`，可加默认 pass |
| `compiler-explorer.local.properties` | 超时 / 并发 / 输出上限 / 危险 flag 黑名单 |
| `execution.local.properties` | 沙箱开关（VM 边界下为 none，不用 nsjail） |

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

- **隔离 = QEMU/KVM VM**：CE 跑在独立内核的 VM，hypervisor 硬边界；共享机上别的租户不受影响。
  共享宿主机**零改动**（不碰 cgroup/userns/AppArmor）。
- **容器最小权限**（VM 内的 CE 容器）：非 root、`read_only` 根文件系统、`cap_drop ALL`、
  `no-new-privileges`、`/tmp` 为 `noexec` tmpfs、`pids_limit` 挡 fork 炸弹。
- 外部 nginx（用 `nginx/ce.conf`）：安全响应头（nosniff / frame / CSP / Referrer-Policy 等）、
  `limit_req` 限流、`client_max_body_size 16m`；CE 经 hostfwd 只到宿主机回环，不直接对内网开放。
- 危险编译选项黑名单：`optionsForbiddenRe=--plugin|-fplugin|--wrapper`。
- **供应链完整性**：`update-clang-gcc.sh` 每次实际下载后核对 SHA256。在 `.env` 钉住
  `LLVM_SHA256` / `GCC_SHA256` / `GCC_RISCV_SHA256` 即强制比对、不符即中止；
  LLVM 包还会在有 `gpg` 时用官方 `.sig` 验签。prepkg 不发校验文件，只能靠钉哈希。
  （首次先留空跑一次拿到脚本打印的哈希，核对官方后填回 `.env` 钉死。）
- 镜像基于固定版本基底构建；建议纳入常规镜像/依赖漏洞扫描。

## 故障排查

- **`logs qemu` 报没有 /dev/kvm**：部署机没 KVM 或没开嵌套虚拟化。entrypoint 会拒绝启动而不是硬撑。
- **CE 没起来 / 看不到 VM 输出**：`docker compose -f docker-compose.vm.yml logs -f qemu` 看串口日志与
  cloud-init 进度（首启要下镜像 + 构建 CE，可能几分钟）。
- **确认 CE 在 VM 里**：`docker compose -f docker-compose.vm.yml exec qemu ...` 不便时，可直接
  `ssh`/串口进 VM 跑 `docker compose -f /srv/ce-repo/docker-compose.yml ps`。
- **工具链更新后 VM 里没生效**：工具链经 9p 是实时的；若 CE 没感知，进 VM `docker compose restart ce`。
- **改了 CE 配置没生效**：cloud-init 只在首启拷仓库。改配置后重建 VM：
  `docker compose -f docker-compose.vm.yml down -v && up -d`。
- **SELinux（宿主机 Enforcing）**：9p 共享宿主机目录给 QEMU 容器，挂载点要能被容器读；
  必要时给 `docker-compose.vm.yml` 里那两个挂载追加 `:z`。
- **某编译器不出现在下拉框**：进 VM 看 `docker compose logs ce | grep -i <名字>`；多为 `exe` 路径或符号链接断。
  确认宿主机 `<CE_COMPILERS_ROOT>/*-latest` 指向有效目录。
- **编译报找不到 libstdc++/启动文件**：检查 `c++.local.properties` 的
  `--gcc-toolchain=/opt/compiler-explorer/gcc-latest` 是否指向有效 GCC。
- **RISC-V 交叉编译找不到 C 库头文件**：在 `clangriscv` 那条补 `--sysroot=<gcc-riscv-latest>/riscv64-linux-gnu/sysroot`
  （确切路径以实际解压为准，见 `c++.local.properties` 注释）。
- **MLIR fork 起不来**：多半缺运行库 → 设 `compiler.myopt.ldPath`（见上）。
