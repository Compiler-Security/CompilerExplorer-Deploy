# 内网自托管 Compiler Explorer

默认在 Docker 中运行 QEMU/KVM，Compiler Explorer（CE）在 Ubuntu guest 内以非 root 用户运行，并用 nsjail 隔离编译。Kata Containers 是备选路径。部署本身不提供认证和 TLS，入口应交给外部 nginx。

```text
nginx → 127.0.0.1:10240 → QEMU/KVM → CE + nsjail
                                      ├─ /opt/compiler-explorer（宿主工具链，只读）
                                      └─ /mnt/ce-repo（配置与装配脚本，只读）
```

## 部署

宿主机需要 Docker Compose 和 `/dev/kvm`；运行完整工具链更新还需要 `python3`（解析 Lean release）和 `zstd`（解压 Lean `.tar.zst`）。若宿主机本身是 VM，需开启嵌套虚拟化。

```bash
cp .env.example .env
# 将 CE_COMPILERS_ROOT 改为宿主机绝对路径。

scripts/update-toolchains.sh
docker compose up -d --build
docker compose logs -f
```

首次启动会下载 Ubuntu 26.04 云镜像，并在 guest 内安装 Node、nsjail 和 CE。健康后验证：

```bash
curl http://127.0.0.1:10240/api/compilers
```

外部代理可使用 [nginx/ce.conf](nginx/ce.conf)，部署前修改 `server_name`。

## Docker、系统镜像与 overlay

本部署有四个独立层次，不能把“重建 Docker”和“重建 VM”混为一件事：

| 层次 | 内容 | 什么时候需要或会重建 |
|---|---|---|
| QEMU Docker 镜像 `ssct/ce-qemu:local` | QEMU、curl、socat 等运行环境 | 仅 `vm/Dockerfile` 或其中安装的软件变化时需要重新 build；普通脚本和配置通过 bind mount 提供，不在镜像内 |
| Docker 容器 `ce-vm` | 端口、挂载、资源限制和传给入口脚本的环境变量 | `compose.yaml` 或相关 `.env` 参数变化时需要 recreate；recreate 不会删除 named volume |
| Ubuntu 基础镜像 `base.img` | 未装配 CE 的 Ubuntu 26.04 cloud image | 文件不存在，或 `VM_IMAGE_URL`、`VM_IMAGE_SHA256`、`VM_IMAGE_SHA256_URL` 变化时自动重新下载；来源标记缺失也会重新下载 |
| CE overlay `ce-vm.qcow2` | Node、nsjail、CE checkout、npm 依赖和构建结果 | 装配指纹变化、上次装配失败、基础镜像缺失或收到新的强制令牌时自动重建 |

基础镜像和 overlay 都位于 Docker volume `ce-vm_vm-disk`。工具链位于宿主机 `CE_COMPILERS_ROOT`，不属于任何 VM 磁盘，因此重建 overlay 不会重新下载工具链。

### Docker 镜像与容器

`docker compose restart qemu` 只重启现有容器：不会重新 build 镜像、不会重新读取 Compose 环境、不会删除磁盘。仓库挂载内容会立即可见，入口脚本会在容器启动时判断是否需要重建 overlay。

以下变化只需要 recreate 容器，不需要重建 QEMU Docker 镜像：

- VM CPU、内存、Docker 资源限制或端口变化。
- `.env` 中传入容器的变量变化。
- Compose 的挂载或安全设置变化。

```bash
docker compose up -d --force-recreate qemu
```

只有 `vm/Dockerfile` 或其中的软件依赖变化时才需要同时 rebuild Docker 镜像：

```bash
docker compose up -d --build --force-recreate qemu
```

### Ubuntu 基础镜像

基础镜像不是本地构建的，而是下载并校验的。修改镜像 URL 或校验参数后，需 recreate 容器让新环境变量生效；入口脚本随后自动替换基础镜像，并同时重建依赖它的 overlay。

只有明确需要删除全部 VM 磁盘和基础镜像缓存时才执行：

```bash
docker compose down -v
```

### CE overlay

以下任一变化都会在下次 QEMU 启动时自动重建 overlay，并完整重装 Node、nsjail、CE，重新执行 `npm ci`、webpack 和 TypeScript 编译：

- `CE_REF`、`VM_DISK_SIZE`、`NODE_VERSION` 或 `NODE_SHA256` 变化。
- 注入的 SSH 公钥内容变化。
- `vm/cloud-init/meta-data` 或 `vm/cloud-init/user-data` 变化。
- `vm/provision-ce.sh`、`vm/setup-nsjail-cgroups.sh`、`vm/ce.service` 或 `scripts/apply-ce-patches.sh` 变化。
- `vm/patches/*.patch` 新增、删除或内容变化。
- 上次装配没有通过 CE 健康检查，缺少完成标记。
- Ubuntu 基础镜像被替换或丢失。
- 使用尚未执行过的 `FORCE_REPROVISION` 令牌。

```bash
FORCE_REPROVISION="$(date +%s%N)" docker compose up -d --force-recreate qemu
```

以下变化不会重建 overlay：修改 `config/*.local.properties`、更新外部工具链、调整 VM CPU/内存、普通重启或仅 recreate 容器。配置变化只需重启 `ce.service`；工具链更新脚本也只重启 CE。

guest 只读取仓库的 `config/`、`scripts/` 和 `vm/`，不会读取 `.env` 或 `.git`。

### 修改后的最小操作

| 修改内容 | 最小操作 | 会重建什么 |
|---|---|---|
| README 或其它纯文档 | 无 | 无 |
| `nginx/ce.conf` | 检查配置并 reload nginx | 无 |
| `config/*.local.properties` | 重启 `ce.service` | 仅 CE 进程，不重建 Docker 或磁盘 |
| `CE_COMPILERS_ROOT` 中的工具链内容或 `*-latest` 软链 | 重启 `ce.service`；工具链更新脚本会自动处理 | 仅 CE 进程 |
| `vm/sync-ce-config.sh` | 重启 `ce.service` | 仅 CE 进程 |
| `vm/entrypoint.sh` | `docker compose restart qemu` | 重启容器和 guest；是否重建 overlay 由新入口逻辑判断 |
| VM CPU/内存、端口、Docker 资源限制或工具链挂载路径 | `docker compose up -d --force-recreate qemu` | 仅 recreate 容器，不重建镜像或磁盘 |
| `.env` 中的 `CE_REF`、Node、磁盘大小或 SSH 公钥配置 | `docker compose up -d --force-recreate qemu` | 自动重建 overlay，并重新构建 CE |
| cloud-init、装配脚本、CE unit 或 patch | `docker compose restart qemu` | 自动重建 overlay，并重新构建 CE |
| `vm/Dockerfile` 或 QEMU 镜像依赖 | `docker compose up -d --build --force-recreate qemu` | 重建 Docker 镜像并 recreate 容器；磁盘默认保留 |
| Ubuntu 镜像 URL 或校验参数 | recreate QEMU 容器 | 自动替换 `base.img` 并重建 overlay |

重启 CE 的管理命令为：

```bash
ssh -i "$CE_VM_SSH_KEY" -p "${CE_VM_SSH_PORT:-2223}" \
  ce@127.0.0.1 'sudo systemctl restart ce.service'
```

若未配置 SSH 管理密钥，可执行 `docker compose restart qemu`，代价是整个 guest 会重启，但正常情况下不会重建 overlay。

## 更新

| 内容 | 命令 |
|---|---|
| 全部标准工具链 | `scripts/update-toolchains.sh [Lean版本号\|latest]` |
| Clang/LLVM | `scripts/toolchains/update-clang.sh` |
| GCC | `scripts/toolchains/update-gcc.sh [x86_64\|riscv64\|all]` |
| Lean 4 | `scripts/toolchains/update-lean4.sh [版本号\|latest]` |
| 自研 P4 工具链 | `scripts/toolchains/deploy-p4.sh <p4mlir-short_hash.tar.gz>` |
| CE 本体 | `scripts/update-ce.sh gh-<release>` |

工具链使用版本目录和相对 `*-latest` 软链。更新器会从真实二进制读取版本并同步 CE 配置，因此版本升级产生配置 Git diff 是预期行为。统一入口在全部更新后只重启一次 CE。

Jenkins 与部署机分离时，自研工具链的 CI 自动发布流程（最小权限用户、密钥模型、Jenkinsfile）见 [docs/jenkins-toolchain-deploy.md](docs/jenkins-toolchain-deploy.md)。

若 `.env` 配置了管理密钥，更新器会通过 SSH 重启 CE：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ce_vm_key -N ''
# 写入 .env：
CE_VM_SSH_PORT=2223
CE_VM_SSH_KEY=/path/to/ce_vm_key
CE_VM_SSH_PUBKEY=/path/to/ce_vm_key.pub
```

没有密钥时按脚本提示执行 `docker compose restart qemu`。

## 工具链与配置

默认加载 `c,c++,lean,llvm,llvm_mir,llvm_p4,mlir,p4`：

- Clang 包提供 C/C++、LLVM IR 的 `clang`/`opt`/`llc` 和 LLVM MIR 的 `llc`。
- GCC 包提供 x86_64 与 riscv64 工具链。
- Lean 更新器安装并验证 `lean` 与 `leanc`。
- 自研 P4 工具链以 `p4mlir-<short_hash>.tar.gz` 发布为 `p4mlir-<short_hash>/` 并切换 `p4-latest` 软链，包含 p4c、p4mlir 系列工具与 P4 修改版 LLVM；缺少时对应编译器隐藏。
- MLIR 编译器 p4mlir-opt、p4mlir-to-json、mlir-translate 来自 `p4-latest`。
- LLVM IR P4 由 patch 添加，与 LLVM IR 同模式；编译器 P4 opt (latest)、P4 llc (latest) 来自 `p4-latest`。
- Alive2 只预配置 `/opt/compiler-explorer/alive2-latest/bin/alive-tv`；缺少时菜单隐藏且启动 warning 属于预期。
- P4 patch 提供语言、图标和语法高亮；编译器 p4c、p4mlir-translate 来自 `p4-latest`。

语言配置集中在 `config/<语言>.local.properties`；全局资源与安全限制位于 `compiler-explorer.local.properties`，nsjail 入口位于 `execution.local.properties`。

默认只允许编译，不运行用户程序。源码定制位于 `vm/patches/`，`scripts/apply-ce-patches.sh` 按四位数字前缀依次应用；升级 `CE_REF` 时需确认补丁仍可应用。

## Kata 备选路径

```bash
sudo kata/setup.sh
docker compose -f compose.kata.yaml up -d --build
```

该路径固定使用 `runtime: kata`，不再启用容器内 nsjail；配置或工具链变化后执行 `docker compose -f compose.kata.yaml restart ce`。根文件系统只读，缓存和本地存储位于 tmpfs。

## 排障

- `/dev/kvm` 不存在：启用 KVM 或嵌套虚拟化。
- 端口冲突：释放 `10240`；SSH 端口可用 `CE_VM_SSH_PORT` 修改。
- 装配日志：`docker compose logs -f qemu`。
- CE 服务：VM 内执行 `journalctl -u ce -e`。
- 工具链在 QEMU 容器内是 `/share/compilers`，在 guest 内是 `/opt/compiler-explorer`。
- 编译器未出现：检查对应相对 `*-latest` 软链和必要二进制，再重启 `ce.service`。
- 配置未生效：检查 `/opt/ce/etc/config/*.local.properties` 是否指向 `/mnt/ce-repo/config/`。
- nsjail 失败：检查 `ce-cgroups.service`，并确认 `/sys/fs/cgroup/ce-{compile,sandbox}` 与 `/cefs` 存在；装配自检会输出详细 errno。
- SELinux Enforcing 阻止读取：按 Compose 注释给只读 bind mount 添加 `z` 标签。

端口只绑定回环，Compose 丢弃 capabilities 并启用 `no-new-privileges`。生产环境仍应固定已核对的镜像/工具链哈希，并在 nginx 层提供认证、TLS 和限流。
