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

## 持久化与同步

- 工具链保存在 `CE_COMPILERS_ROOT`，通过只读 9p 挂载到 guest。
- 基础镜像和 qcow2 overlay 保存在 Docker volume `ce-vm_vm-disk`；普通重启不会重建。
- `ce.service` 每次启动都会重新链接全部 `config/*.local.properties`，所以配置增删只需重启 CE。
- `CE_REF`、磁盘大小、Node、SSH 公钥、cloud-init、装配脚本、systemd unit 或 patch 变化时，会保留基础镜像并自动重建 overlay。
- 首次装配只有在 CE 健康检查成功后才记录完成；中途失败的 overlay 会在下次启动时重建。

guest 只读取仓库的 `config/`、`scripts/` 和 `vm/`，不会读取 `.env` 或 `.git`。

## 更新

| 内容 | 命令 |
|---|---|
| 全部标准工具链 | `scripts/update-toolchains.sh [Lean版本号\|latest]` |
| Clang/LLVM | `scripts/toolchains/update-clang.sh` |
| GCC | `scripts/toolchains/update-gcc.sh [x86_64\|riscv64\|all]` |
| Lean 4 | `scripts/toolchains/update-lean4.sh [版本号\|latest]` |
| 自研 MLIR | `scripts/toolchains/deploy-mlir.sh <产物目录> <build-id>` |
| CE 本体 | `scripts/update-ce.sh gh-<release>` |

工具链使用版本目录和相对 `*-latest` 软链。更新器会从真实二进制读取版本并同步 CE 配置，因此版本升级产生配置 Git diff 是预期行为。统一入口在全部更新后只重启一次 CE。

若 `.env` 配置了管理密钥，更新器会通过 SSH 重启 CE：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ce_vm_key -N ''
# 写入 .env：
CE_VM_SSH_PORT=2223
CE_VM_SSH_KEY=/path/to/ce_vm_key
CE_VM_SSH_PUBKEY=/path/to/ce_vm_key.pub
```

没有密钥时按脚本提示执行 `docker compose restart qemu`。仅在明确需要全新装配时使用一次性令牌：

```bash
FORCE_REPROVISION="$(date +%s%N)" docker compose up -d --force-recreate qemu
```

删除基础镜像和 overlay：

```bash
docker compose down -v
```

## 工具链与配置

默认加载 `c,c++,lean,llvm,llvm_mir,mlir,p4`：

- Clang 包提供 C/C++、LLVM IR 的 `clang`/`opt`/`llc` 和 LLVM MIR 的 `llc`。
- GCC 包提供 x86_64 与 riscv64 工具链。
- Lean 更新器安装并验证 `lean` 与 `leanc`。
- 自研 MLIR 发布到 `mlir-custom`；缺少时对应编译器隐藏。
- Alive2 只预配置 `/opt/compiler-explorer/alive2-latest/bin/alive-tv`；缺少时菜单隐藏且启动 warning 属于预期。
- P4 patch 只提供语言、图标和语法高亮，不安装编译器。

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
