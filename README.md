# 内网自托管 Compiler Explorer

面向受信内网的 Compiler Explorer 部署。主路径是在 Docker 中运行 QEMU/KVM，CE 在 guest 内以非 root 用户运行，并用 nsjail 隔离编译；Kata Containers 仅作为备选路径。默认不提供认证和 TLS，应由外部 nginx 负责入口和限流。

```text
nginx → 127.0.0.1:10240 → QEMU/KVM VM → CE + nsjail
                              ├─ /opt/compiler-explorer（宿主机工具链，只读）
                              └─ /mnt/ce-repo（部署配置与脚本，只读）
```

## 快速部署

宿主机需要 Docker Compose、`/dev/kvm`、`python3` 和 `zstd`。若宿主机本身是 VM，需开启嵌套虚拟化。`python3` 用于解析 Lean GitHub release 元数据，`zstd` 用于解压官方 `.tar.zst` 工具链。

```bash
cp .env.example .env
# 修改 CE_COMPILERS_ROOT；它必须是宿主机绝对路径。

scripts/update-toolchains.sh
docker compose -f docker-compose.vm.yml up -d --build qemu
docker compose -f docker-compose.vm.yml logs -f qemu
```

首次启动会下载 Ubuntu 26.04 云镜像，并在 VM 内安装 Node、nsjail 和 CE。完成后验证：

```bash
curl http://127.0.0.1:10240/api/compilers
```

将 [nginx/ce.conf](nginx/ce.conf) 放进现有 nginx 的 `conf.d/`，修改 `server_name` 后 reload。

工具链保存在 `CE_COMPILERS_ROOT`。虚拟磁盘保存在 Docker named volume `ce-vm_vm-disk`，不在 QEMU 容器可写层中。guest 只共享仓库的 `config/`、`scripts/` 和 `vm/`，不会读取 `.env` 或 `.git`。

## 更新

| 内容 | 命令 | 重建 VM |
|---|---|---|
| 全部标准工具链 | `scripts/update-toolchains.sh [Lean版本号\|latest]` | 否 |
| Clang/LLVM | `scripts/toolchains/update-clang.sh` | 否 |
| GCC | `scripts/toolchains/update-gcc.sh [x86_64\|riscv64\|all]` | 否 |
| Lean 4 | `scripts/toolchains/update-lean4.sh [版本号\|latest]` | 否 |
| 自研 MLIR | `scripts/toolchains/deploy-mlir.sh <产物目录> <build-id>` | 否 |
| CE 本体 | `scripts/update-ce.sh gh-<release>` | 是 |

标准工具链更新器使用版本目录和相对 `*-latest` 软链。安装后会读取真实二进制版本，原子同步 CE 配置；版本升级产生配置 Git diff 属于预期行为。统一入口只在全部更新结束后重启一次 CE。

若 `.env` 配置了 `CE_VM_SSH_KEY`，更新器会通过 SSH 重启 CE；否则按提示重启 QEMU 容器。可选管理通道配置：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ce_vm_key -N ''
```

```dotenv
CE_VM_SSH_PORT=2223
CE_VM_SSH_KEY=/path/to/ce_vm_key
CE_VM_SSH_PUBKEY=/path/to/ce_vm_key.pub
```

SSH 公钥、Node 版本或装配状态变化时，用新的令牌重建 overlay：

```bash
FORCE_REPROVISION="$(date +%s%N)" \
  docker compose -f docker-compose.vm.yml up -d --force-recreate qemu
```

同一令牌只执行一次删盘。若要连同基础镜像和 overlay 一起清理：

```bash
docker compose -f docker-compose.vm.yml down -v
```

## 工具链与语言

- Clang 包同时提供 C/C++、LLVM IR 的 clang/`opt`/`llc`，以及 LLVM MIR 的 `llc`。
- GCC 更新器安装 x86_64 与 riscv64 工具链。
- Lean 更新器安装官方完整工具链，并验证 `lean` 与 `leanc`。
- MLIR 不包含在标准更新中，由 Jenkins 发布到稳定软链 `mlir-custom`。
- Alive2 仅预配置为 LLVM IR 工具。缺少 `alive2-latest/bin/alive-tv` 时菜单隐藏，启动 warning 属于预期行为。
- P4 patch 只添加语言、图标和 Monaco 高亮，不安装 P4 编译器。

MLIR 发布示例：

```groovy
stage('deploy to CE') {
  steps {
    sh '/path/to/repo/scripts/toolchains/deploy-mlir.sh "$WORKSPACE/build/install" "$BUILD_NUMBER"'
  }
}
```

产物必须包含可执行的 `bin/mlir-opt` 和 `bin/mlir-translate`。发布脚本原子切换软链，并保留当前版本和最近三个回滚版本。

默认仅加载 `c,c++,lean,llvm,llvm_mir,mlir,p4`；CE 会额外保留项目构建清单语言。源码定制位于 `vm/patches/`，由 `scripts/apply-ce-patches.sh` 按四位数字前缀顺序应用。升级 `CE_REF` 时应先检查 patch 是否仍可应用。

## 配置

| 文件 | 内容 |
|---|---|
| `config/c.local.properties` | C 的 Clang/GCC 与 riscv64 交叉编译 |
| `config/c++.local.properties` | C++ 的 Clang/GCC 与 riscv64 交叉编译 |
| `config/lean.local.properties` | Lean 4 |
| `config/llvm.local.properties` | LLVM IR 与 Alive2 |
| `config/llvm_mir.local.properties` | LLVM MIR |
| `config/mlir.local.properties` | 自研 MLIR |
| `config/compiler-explorer.local.properties` | 语言范围、资源和安全限制 |
| `config/execution.local.properties` | QEMU guest 的 nsjail 配置 |

默认只允许编译，不运行用户程序。需要运行 x86_64 产物时，将相应语言的 `supportsExecute` 改为 `true` 后重启 CE；riscv64 仍需 qemu-user。

常见定制项直接添加到对应 compiler：

```properties
# riscv64 Clang 的 sysroot
group.clangriscv.options=--target=riscv64-linux-gnu --gcc-toolchain=/opt/compiler-explorer/gcc-riscv-latest --sysroot=<path>

# MLIR 默认参数与运行库
compiler.mlir-opt.options=--mlir-print-ir-after-all
compiler.mlir-opt.ldPath=/opt/compiler-explorer/mlir-custom/lib
```

## Kata 备选路径

在专用宿主机安装并注册 Kata runtime：

```bash
sudo scripts/setup-kata.sh
docker compose up -d --build
```

`docker-compose.yml` 固定使用 `runtime: kata`，不再启用容器内 nsjail。根文件系统只读，缓存和本地存储位于 tmpfs，容器重建后不保留。该路径更新配置或工具链后使用 `docker compose restart ce`；`scripts/update-ce.sh` 仅适用于 QEMU 主路径。

## 安全边界

- CE 以 uid 10001 运行；QEMU 路径使用 VM + nsjail，Kata 路径使用 Kata VM。
- Compose 丢弃 capabilities、启用 `no-new-privileges`，端口仅绑定回环。
- 工具链、Ubuntu 镜像、Node 和 Kata 支持 SHA256 校验；生产环境建议在 `.env` 固定已核对的哈希。
- nginx 限制请求大小和速率；认证、TLS 和更严格 CSP 由部署方提供。
- guest 默认可通过 user-mode NAT 出网。

## 排障

- `/dev/kvm` 不存在：启用 KVM 或嵌套虚拟化。
- `10240` 或 SSH 端口冲突：释放占用；SSH 端口可通过 `CE_VM_SSH_PORT` 修改。
- 查看装配日志：`docker compose -f docker-compose.vm.yml logs -f qemu`。
- 查看 CE 服务：VM 内执行 `journalctl -u ce -e`。
- 工具链在 QEMU 容器内位于 `/share/compilers`，在 guest 内位于 `/opt/compiler-explorer`；不要在 QEMU 容器里查后者。
- 编译器未出现：检查对应 `*-latest` 是否为同目录相对软链，并重启 `ce.service`。
- LLVM IR/MIR 未出现：分别检查 `clang-latest/bin/clang++` 与 `clang-latest/bin/llc`。
- Lean 未出现：检查 `lean-latest/bin/lean` 和 `bin/leanc`。
- MLIR 未出现：检查 `mlir-custom/bin/mlir-opt` 和 `bin/mlir-translate`。
- 配置未生效：重启 `ce.service`；只有装配期参数需要 `FORCE_REPROVISION`。
- SELinux Enforcing 阻止读取：按 Compose 注释给只读 bind mount 添加 `z` 标签。
