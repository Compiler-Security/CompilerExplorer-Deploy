# 内网自托管 CompilerExplorer（Clang/LLVM + GCC + 自研 MLIR）

一键部署的 CompilerExplorer，跑在一个 **QEMU/KVM VM** 里，而这个 VM 由一个 Docker 容器启动。
内置可独立更新的工具链：

- **Clang/LLVM**（官方预编译，最新版；**全后端通用** —— 同一份 clang 加 `--target=riscv64-linux-gnu` 即可交叉 RISC-V）
- **GCC x86_64 原生 + GCC riscv64 交叉**（prepkg 预编译，GCC 最新，glibc 2.17 基线）
- **Clang riscv64 交叉**（复用 clang 二进制 + `--target`，无需单独下载）
- **自研 MLIR**（你们 Jenkins 每次提交 build，自动发布生效）

实例面向内网，**不加认证、不做 TLS**，但按公网标准加固。

## 隔离模型：Docker 里起 QEMU/KVM VM，CE 直接跑在 VM 内

```
共享宿主机
 ├─ <CE_COMPILERS_ROOT>/            # 工具链根（9p 只读共享进 VM; 路径在 .env 配）
 │    ├─ clang-<date>/  ← clang-latest (符号链接)
 │    ├─ gcc-<triple>-<date>/ ← gcc-latest / gcc-riscv-latest (符号链接)
 │    └─ mlir-custom.<build#>/ ← mlir-custom (符号链接)
 │
 ├─ docker compose -f docker-compose.vm.yml
 │    └─ qemu 容器（--device /dev/kvm）          ← 宿主机唯一暴露面
 │         └─ QEMU/KVM VM（独立内核, 8C/8G, virtio disk + user-net）
 │              └─ CE 直接跑在 VM 上：node + systemd 服务 + nsjail
 │                   （无内层 docker；nsjail 是裸机写法，不踩容器嵌套坑）
 │
 └─ 外部已有 nginx ── 反代到 127.0.0.1:10240 →(QEMU hostfwd)→ VM 的 CE
        另: 宿主 127.0.0.1:2222 →(hostfwd)→ VM:22（SSH 管理 CE，可选）
```

**隔离分两层**（纵深防御）：
- **VM（hypervisor 硬边界）**——对共享宿主机。宿主**零改动**（不碰 cgroup/userns/AppArmor），别的租户不受影响。
- **nsjail（VM 内）**——对每次编译/运行再沙箱一次。VM 是专用的，所以 nsjail 用最标准的裸机写法。

前提：部署机有 `/dev/kvm`（若部署机本身是 VM，需开嵌套虚拟化）。

> **备选**：若有一台装了 [Kata Containers](https://katacontainers.io/) 的专用机，可以不套 QEMU、让 CE 直接以
> 容器跑在 Kata VM 里——用 `Dockerfile` + `docker-compose.yml` + `scripts/setup-kata.sh`（该路径保留为备选，
> 本仓库主线是上面的 QEMU-in-Docker + VM 内直跑）。

## 首次部署

```bash
# 0. 配置 .env
cp .env.example .env
#    必填: CE_COMPILERS_ROOT（宿主机工具链根）
#    可选: CE_REF（CE 版本）、CE_VM_SSH_KEY / CE_VM_SSH_PUBKEY（见下「SSH 管理通道」）

# 1. 准备工具链目录（至少各放一份，并建好符号链接）
mkdir -p "$(grep -E '^CE_COMPILERS_ROOT=' .env | cut -d= -f2)"
scripts/update-clang-gcc.sh all        # 自动下载 Clang + 两种 GCC；或分开: clang / gcc / gcc-riscv
#   - MLIR: 你们 Jenkins build 产物解压为 mlir-custom.<id>，ln -s 指向 mlir-custom

# 2. 起 QEMU/KVM VM（首启：下载云镜像 + cloud-init 装配 + 在 VM 内构建 CE，较慢）
docker compose -f docker-compose.vm.yml build qemu
docker compose -f docker-compose.vm.yml up -d
docker compose -f docker-compose.vm.yml logs -f qemu   # 看 VM 串口日志 / cloud-init 进度

# 3. 让外部 nginx 反代到 127.0.0.1:10240（把 nginx/ce.conf 丢进其 conf.d/，改 server_name 后 reload）

# 4. 验证
curl http://127.0.0.1:10240/api/compilers   # 应列出 clang/gcc/mlir-opt
```

浏览器访问 `http://<服务器IP>/`，选语言（C++ 或 MLIR）与编译器即可。

## 更新

### 工具链（MLIR / Clang / GCC）—— 不动 VM

工具链走宿主机目录 + 9p 共享，**实时反映进 VM**，无需重建。更新脚本：

```bash
scripts/update-clang-gcc.sh {clang|gcc|gcc-riscv|all}   # 幂等：版本没变就不重下
scripts/deploy-mlir.sh <产物目录> <build#>               # 由 Jenkins 调用
```

两个脚本更新宿主机目录后会**尝试 SSH 进 VM 重启 CE**（清编译缓存/刷新版本显示）。
这是 best-effort——不配 SSH 也不影响新工具链下次编译生效（exe 走符号链接）。

### CE 本体 —— 重建 VM 装配

```bash
scripts/update-ce.sh gh-<new-tag>
```

改 `.env` 的 `CE_REF` → force-recreate qemu 容器 → VM 的 entrypoint 检测到版本变化会
重建 VM 磁盘（保留云镜像底包不重下）→ cloud-init 按新 tag 重新装配 CE。期间 CE 停机几分钟。

**只想改配置 / 加 SSH 公钥 / 上次装配失败要恢复**（CE_REF 没变也想强制重新装配）：

```bash
FORCE_REPROVISION=1 docker compose -f docker-compose.vm.yml up -d --force-recreate qemu
```

> 说明：CE 的覆盖配置（`config/*.local.properties`）在 VM 里是**符号链接到 9p 实时共享**的，
> 所以改配置一般不用重建 VM——SSH 进 VM `sudo systemctl restart ce.service` 即可生效。
> 只有 CE 版本、SSH 公钥这类「首次装配才写进 guest」的东西才需要 FORCE_REPROVISION。

### SSH 管理通道（可选）

工具链更新后要**立即**清 CE 缓存，需能从宿主机进 VM 重启 CE。配置：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ce_vm_key -N ''
# .env 里设:
#   CE_VM_SSH_KEY=/path/to/.ssh/ce_vm_key       # 私钥（脚本用）
#   CE_VM_SSH_PUBKEY=/path/to/.ssh/ce_vm_key.pub # 公钥（注入 VM 的 ce 用户）
# 公钥是首次装配时写进 guest 的，后加/更换公钥要强制重配：
FORCE_REPROVISION=1 docker compose -f docker-compose.vm.yml up -d --force-recreate qemu
```

VM 内 `ce` 用户的 sudo 只放行 `systemctl restart/status/is-active ce.service`（最小权限）。

## 接 Jenkins（MLIR 自动发布）

在你们**已有的 MLIR Jenkins job** 末尾加一个 deploy 阶段：

```groovy
stage('deploy to CE') {
  steps {
    // 路径指向部署机上的本仓库；脚本读 .env 的 CE_COMPILERS_ROOT，并 best-effort SSH 重启 CE
    sh '/path/to/ssct-compiler-explorer/scripts/deploy-mlir.sh "$WORKSPACE/build/install" "$BUILD_NUMBER"'
  }
}
```

脚本 rsync 产物到 `mlir-custom.<build#>` → 原子切 `mlir-custom` 链接（经 9p 实时进 VM）→ 保留最近 3 个旧版本可回滚。

**不需要为 CE 部署单独建 Jenkins job**：Clang/GCC 手动跑脚本（或低频定时），CE 本体手动跑 `update-ce.sh`。

## 配置

所有 CE 覆盖配置在 `config/*.local.properties`，**改完需让 VM 里的 CE 重读**（进 VM `systemctl restart ce`，或 `update-ce.sh` 重建）：

| 文件 | 作用 |
|---|---|
| `c++.local.properties` | 登记 Clang/GCC（`--gcc-toolchain`、demangler、Intel asm、riscv 交叉）、`supportsExecute` 开关 |
| `mlir.local.properties` | 登记自研 `mlir-opt` / `mlir-translate`，可加默认 pass |
| `compiler-explorer.local.properties` | 超时 / 并发 / 输出上限 / 危险 flag 黑名单 |
| `execution.local.properties` | nsjail 沙箱开关（编译器 + 用户程序） |

### 给 MLIR 设默认 pass

`mlir.local.properties` 里：

```properties
compiler.myopt.options=--mlir-print-ir-after-all
```

### 自研工具链库路径

若 fork 的运行库不在系统路径，在 `mlir.local.properties` 加：

```properties
compiler.myopt.ldPath=/opt/compiler-explorer/mlir-custom/lib
```

## 安全说明（按公网标准，未开认证/TLS）

- **VM（hypervisor 硬边界）**：CE 跑在独立内核的 VM；共享宿主机零改动，别的租户不受影响。
- **nsjail（VM 内）**：编译器沙箱（只读挂载、1.25GiB/72进程/单核、noexec tmpfs、无网络）+ 用户程序沙箱
  （仅当 `supportsExecute=true`，更严）。当前默认只编译不运行。
- **CE 进程**（VM 内）：非 root（uid 10001）、systemd 管理；SSH 进 VM 的 ce 用户 sudo 只放行 ce.service 的重启。
- 外部 nginx（用 `nginx/ce.conf`）：安全响应头、限流、`client_max_body_size 16m`；CE 只到宿主机回环。
- 危险编译选项黑名单：`optionsForbiddenRe=--plugin|-fplugin|--wrapper`。
- **供应链完整性**：`update-clang-gcc.sh` 每次实际下载后核对 SHA256（`.env` 钉 `LLVM_SHA256` / `GCC_SHA256` /
  `GCC_RISCV_SHA256` 即强制比对、不符即中止）；LLVM 包在有 `gpg` 时用官方 `.sig` 验签；prepkg 只能钉哈希。
  云镜像与 Node tarball 同理：`VM_IMAGE_SHA256` / `NODE_SHA256` 钉值校验（Node 默认也会用官方 SHASUMS256.txt 核对）。
- 建议把 CE 依赖纳入常规漏洞扫描。

**已知残留（按需再加固）**：Guest 出口网络默认未限制（user-net NAT；要锁可在装配后把 QEMU 网络改成仅 hostfwd）；
CE 升级是重建 overlay、无快照回滚（底包保留，可在删前手动备份旧 overlay）；优雅关机走 ACPI powerdown（monitor socket），
极端卡死仍靠超时强杀。

## 故障排查

- **`logs qemu` 报没有 /dev/kvm**：部署机没 KVM 或没开嵌套虚拟化（entrypoint 会拒绝启动而不是硬撑）。
- **CE 一直没起来**：`docker compose -f docker-compose.vm.yml logs -f qemu` 看串口日志 / cloud-init；
  首启要下云镜像 + 在 VM 里构建 CE，可能几分钟。也可 SSH 进 VM `journalctl -u ce -f` 看 CE 服务日志。
- **CE 起来了但某编译器不在下拉框**：SSH 进 VM `journalctl -u ce | grep -i <名字>`；多为 `exe` 路径或符号链接断。
  确认宿主机 `<CE_COMPILERS_ROOT>/*-latest` 指向有效目录。
- **工具链更新后 UI 还是旧版本/旧结果**：CE 有编译缓存。配了 SSH 就让脚本自动重启；否则进 VM
  `sudo systemctl restart ce.service`。
- **编译报找不到 libstdc++/启动文件**：检查 `c++.local.properties` 的
  `--gcc-toolchain=/opt/compiler-explorer/gcc-latest` 是否指向有效 GCC。
- **RISC-V 交叉找不到 C 库头文件**：在 `clangriscv` 那条补 `--sysroot=<gcc-riscv-latest>/riscv64-linux-gnu/sysroot`
  （确切路径以实际解压为准，见 `c++.local.properties` 注释）。
- **MLIR fork 起不来**：多半缺运行库 → 设 `compiler.myopt.ldPath`（见上）。
- **nsjail 报 `Launching child process failed`**：VM 内 cgroup 没建好。provision 已用
  `setup-nsjail-cgroups.sh --install-systemd`（重启不丢）。SSH 进 VM 确认
  `ls -la /sys/fs/cgroup/ce-compile ce-sandbox` 存在且属主是 uid 10001。
- **编译器突然全部消失（VM 重启后）**：9p 挂载没起来。已写入 `/etc/fstab` 持久化；SSH 进 VM 确认
  `mount | grep 9p` 有 compilers/cerepo，没有则 `mount -a`。ce.service 带 `RequiresMountsFor=` 兜底。
- **改了 CE 配置没生效**：配置是软链到 9p 实时共享的，SSH 进 VM `sudo systemctl restart ce.service` 即可。
  若是 CE 版本/SSH 公钥这类首次装配才写入 guest 的，用 `FORCE_REPROVISION=1`（见「CE 本体」一节）。
- **上次装配失败、磁盘坏了起不来**：`FORCE_REPROVISION=1 docker compose -f docker-compose.vm.yml up -d --force-recreate qemu`
  强制重建 VM 磁盘重新装配。
- **SELinux（宿主机 Enforcing）**：9p 共享的目录要能被 qemu 容器读；必要时给 `docker-compose.vm.yml`
  里那两个挂载追加 `:z`。
