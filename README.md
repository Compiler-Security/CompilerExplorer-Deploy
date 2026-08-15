# 内网自托管 Compiler Explorer

面向受信内网的 Compiler Explorer，提供 C/C++、Clang、Lean 4、LLVM IR、P4 语法高亮、x86_64 与 riscv64 GCC，以及 Jenkins 发布的自研 MLIR。默认不含认证和 TLS；外部 nginx 负责入口、限流与安全响应头。

主路径是在 Docker 中启动 QEMU/KVM VM，CE 在 VM 内以非 root 用户运行，并用 nsjail 隔离每次编译。Kata Containers 是保留的备选路径。

## 架构

```text
宿主机
├─ CE_COMPILERS_ROOT/                  # Clang/LLVM/GCC/Lean/MLIR，9p 只读共享
├─ docker-compose.vm.yml
│  └─ QEMU/KVM VM
│     └─ CE + systemd + nsjail
└─ nginx → 127.0.0.1:10240 → VM:10240
             127.0.0.1:2223 → VM:22（可选管理通道）
```

部署机必须提供 `/dev/kvm`；若部署机本身是 VM，需要启用嵌套虚拟化。

## QEMU 主路径

### 首次部署

```bash
cp .env.example .env
# 编辑 .env，至少设置 CE_COMPILERS_ROOT

scripts/update-toolchains.sh
# 自研 MLIR：scripts/deploy-mlir.sh <产物目录> <build-id>

docker compose -f docker-compose.vm.yml build qemu
docker compose -f docker-compose.vm.yml up -d
docker compose -f docker-compose.vm.yml logs -f qemu
```

将 [nginx/ce.conf](nginx/ce.conf) 放入现有 nginx 的 `conf.d/`，修改 `server_name` 后 reload。验证：

```bash
curl http://127.0.0.1:10240/api/compilers
```

首次启动会下载 Ubuntu 26.04 云镜像，并在 VM 内安装 Node、nsjail 和 CE，耗时通常比后续启动长。

`update-clang-gcc.sh clang` 安装的 LLVM 工具链同时提供 C/C++ 下的 Clang，以及 `LLVM IR` 语言下的 clang、`llc` 和 `opt`。MLIR 不随它自动提供；只有执行 `deploy-mlir.sh` 并发布可用的 `mlir-custom` 后，CE 才会显示 `MLIR` 语言。

Lean 4 更新器使用官方 `linux.tar.zst`（当前完整工具链约 575 MB），部署宿主机需安装 `python3` 与 `zstd`。

### 更新

| 内容 | 命令 | 是否重建 VM |
|---|---|---|
| 全部标准工具链 | `scripts/update-toolchains.sh [Lean版本号\|latest]` | 否 |
| Clang/GCC | `scripts/update-clang-gcc.sh {clang\|gcc\|gcc-riscv\|all}` | 否 |
| Lean 4 | `scripts/update-lean4.sh [版本号\|latest]` | 否 |
| 自研 MLIR | `scripts/deploy-mlir.sh <产物目录> <build-id>` | 否 |
| CE 本体 | `scripts/update-ce.sh gh-<release>` | 是 |
| 覆盖配置 | 修改 `config/*.local.properties` 后重启 `ce.service` | 否 |

`update-toolchains.sh` 依次更新 Clang、x86_64 GCC、riscv64 GCC 和 Lean 4，并在发生变化后只重启一次 CE。自研 MLIR 由 Jenkins 和 `deploy-mlir.sh` 发布，不包含在统一更新中。

工具链通过相对软链和 9p 共享给 VM，但 CE 进程需要重启才能重新扫描编译器列表。若 `.env` 配置了 `CE_VM_SSH_KEY`，更新脚本会 best-effort 重启 CE；未配置时可重启 QEMU 容器，或手动执行：

```bash
ssh -i <private-key> -p 2223 ce@127.0.0.1 \
  'sudo systemctl restart ce.service'
```

新增 SSH 公钥、修改 Node 版本，或恢复失败的首次装配时，用一个未使用过的令牌重建 overlay：

```bash
FORCE_REPROVISION="$(date +%s%N)" \
  docker compose -f docker-compose.vm.yml up -d --force-recreate qemu
```

同一令牌只触发一次删盘，避免容器自动重启时反复重建。

### SSH 管理通道（可选）

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ce_vm_key -N ''
```

在 `.env` 中设置：

```dotenv
CE_VM_SSH_KEY=/path/to/ce_vm_key
CE_VM_SSH_PUBKEY=/path/to/ce_vm_key.pub
```

公钥只在装配 guest 时写入；新增或更换后需使用新的 `FORCE_REPROVISION` 令牌。`ce` 用户的 sudo 权限仅覆盖 `ce.service` 的 restart/status/is-active。

## Kata 备选路径

在专用宿主机安装并注册 Kata runtime：

```bash
sudo scripts/setup-kata.sh
docker compose up -d --build
```

`docker-compose.yml` 固定使用 `runtime: kata`，不启用容器内 nsjail。根文件系统只读，缓存和本地存储位于 tmpfs，容器重建后不保留。工具链或配置更新后执行 `docker compose restart ce`；`scripts/update-ce.sh` 仅适用于 QEMU 主路径。

## Jenkins 发布 MLIR

在现有 MLIR job 的成功阶段调用：

```groovy
stage('deploy to CE') {
  steps {
    sh '/path/to/ssct-compiler-explorer/scripts/deploy-mlir.sh "$WORKSPACE/build/install" "$BUILD_NUMBER"'
  }
}
```

产物目录必须包含可执行的 `bin/mlir-opt` 和 `bin/mlir-translate`。脚本先同步到临时目录，再原子切换 `mlir-custom` 相对软链，并保留当前版本与最近 3 个回滚版本。

## 配置

| 文件 | 作用 |
|---|---|
| `config/c.local.properties` | C 的 Clang/GCC 与 riscv64 交叉编译 |
| `config/c++.local.properties` | C++ 的 Clang/GCC、交叉编译与在线运行开关 |
| `config/lean.local.properties` | Lean 4 及同工具链内的 `leanc` |
| `config/llvm.local.properties` | LLVM IR 的 clang、`llc` 与 `opt` |
| `config/mlir.local.properties` | 自研 `mlir-opt` / `mlir-translate` |
| `config/compiler-explorer.local.properties` | 超时、并发、输出上限和危险参数限制 |
| `config/execution.local.properties` | QEMU 路径的 nsjail 配置 |

默认通过 `restrictToLanguages=c,c++,lean,llvm,mlir,p4` 只加载 C、C++、Lean、LLVM IR、MLIR 和 P4。P4 由装配阶段应用的小型 CE 源码补丁提供图标与 Monaco 语法高亮，不安装或替换编译器；编译仍使用部署方已有的定制工具链。CE 为 IDE/项目模式会始终保留 CMake、Cargo、Makefile、Maven 等构建清单语言；它们不会引入额外编译器。

CE 源码定制以有序 patch 队列维护，QEMU 与 Kata 构建均通过 `scripts/apply-ce-patches.sh` 按四位数字前缀幂等应用 `vm/patches/*.patch`。新增补丁使用连续序号命名（如 `0002-description.patch`）；升级 `CE_REF` 时应先对新 tag 执行补丁检查。

默认只允许编译，不运行用户程序。若需要开放 x86_64 产物执行，将 `supportsExecute` 改为 `true` 后重启 CE；riscv64 产物仍需 qemu-user。

MLIR 默认 pass 或运行库路径可在 `config/mlir.local.properties` 中设置：

```properties
compiler.mlir-opt.options=--mlir-print-ir-after-all
compiler.mlir-opt.ldPath=/opt/compiler-explorer/mlir-custom/lib
```

Clang riscv64 找不到 C 库头文件时，按实际 GCC 包布局给 `group.clangriscv.options` 补 `--sysroot`。

## 安全边界

- QEMU 主路径以 VM 隔离共享宿主机，guest 内再以 nsjail 限制编译器和用户程序。
- CE 以 uid 10001 运行；Compose 丢弃 capabilities、启用 `no-new-privileges`，入口只绑定回环。
- nginx 限制请求体和请求速率，并设置基础安全响应头。
- 工具链、Ubuntu 镜像、Node 和 Kata 支持 SHA256 校验；建议在 `.env` 固定已核对的工具链哈希。
- 默认仍允许 guest 经 user-mode NAT 出网；CE 升级通过重建 overlay 完成，没有自动快照回滚。

## 故障排查

- `/dev/kvm` 不存在：启用 KVM 或嵌套虚拟化。
- CE 未启动：查看 `docker compose -f docker-compose.vm.yml logs -f qemu`；VM 内可查 `journalctl -u ce -e`。
- 编译器未出现在列表：确认 `CE_COMPILERS_ROOT/*-latest` 指向存在的同目录相对路径，并在更新工具链后重启 `ce.service` 刷新列表。
- `LLVM IR` 不出现：确认 `clang-latest/bin/clang++` 可执行；旧 VM 还需存在 `/opt/ce/etc/config/llvm.local.properties` 软链。
- `MLIR` 不出现：它不是 Clang 包的默认附带项；先确认 `mlir-custom/bin/mlir-opt` 和 `mlir-translate` 均可执行。
- 更新后仍显示旧结果：重启 `ce.service` 清理 CE 缓存。
- Clang 缺少 libstdc++/启动文件：检查 `--gcc-toolchain=/opt/compiler-explorer/gcc-latest`。
- MLIR 缺运行库：设置 `compiler.mlir-opt.ldPath`。
- nsjail 启动失败：确认 `/sys/fs/cgroup/ce-compile` 和 `ce-sandbox` 存在且归 uid 10001。
- VM 重启后编译器全部消失：确认 `compilers` 与 `cerepo` 两个 9p 挂载存在；必要时在 VM 内执行 `mount -a`。
- 配置未生效：重启 `ce.service`；只有装配期参数才需要 `FORCE_REPROVISION`。
- SELinux Enforcing 阻止读取：按 Compose 注释给只读 bind mount 添加 `z` 标签选项。
