# Jenkins 自动发布工具链

Jenkins 构建机与 CE 部署机分离时，自研工具链（如 MLIR）通过 rsync/SSH 发布，私钥只保存在 Jenkins Credentials。

```text
Jenkins（私钥）
  │  rsync/ssh → ce-deploy@部署机（公钥）
  │    └─ scripts/toolchains/deploy-mlir.sh → CE_COMPILERS_ROOT
  │         └─ 9p 只读挂载 → VM /opt/compiler-explorer
  └─  ssh -J ce-deploy@部署机 → ce@127.0.0.1:2223（同一公钥）
        └─ sudo systemctl restart ce.service
```

## 密钥模型

只使用一把密钥：

- 私钥只存于 Jenkins Credential，不出现在任何服务器磁盘上。
- 公钥安装两处：部署机 `ce-deploy` 的 `authorized_keys` 和 VM 内 `ce` 的 `authorized_keys`。
- 不给 `ce-deploy` 单独配 VM 私钥：Jenkins 能以 `ce-deploy` 执行命令时，第二把私钥会被直接读走，不构成隔离。
- 普通配置（主机、路径、端口）写在 Jenkinsfile 的 `environment` 块，不进 Credentials——Credential 值在日志中会被遮蔽且不可审计。

## 部署机配置

以下示例假设仓库位于 `/home/llm/CompilerExplorer-Deploy`，按实际路径替换。

### 1. 创建最小用户

```bash
sudo useradd --system --create-home \
  --home-dir /var/lib/ce-deploy --shell /bin/bash --user-group ce-deploy
sudo passwd -l ce-deploy
id ce-deploy   # 应只有 ce-deploy 自己的组，无 sudo/docker/kvm
```

### 2. 目录与权限

```bash
DEPLOY_REPO=/home/llm/CompilerExplorer-Deploy
TOOLCHAIN_ROOT="${DEPLOY_REPO}/data/ce/compilers"
INCOMING_ROOT="${DEPLOY_REPO}/data/ce/incoming"

sudo install -d -o ce-deploy -g ce-deploy -m 0750 "${INCOMING_ROOT}"

# 父目录只给 x（可穿过、不可列出）
sudo setfacl -m u:ce-deploy:--x /home/llm
sudo setfacl -m u:ce-deploy:--x "${DEPLOY_REPO}"
sudo setfacl -m u:ce-deploy:--x "${DEPLOY_REPO}/data"
sudo setfacl -m u:ce-deploy:--x "${DEPLOY_REPO}/data/ce"

# 工具链根：发布与清理旧版本需要组写
sudo chgrp -R ce-deploy "${TOOLCHAIN_ROOT}"
sudo chmod -R g+rwX "${TOOLCHAIN_ROOT}"
sudo find "${TOOLCHAIN_ROOT}" -type d -exec chmod g+s {} +
```

目录位于其他用户家目录下时同样适用：父目录一律 `--x`，目标目录按上表授权，不要把 `ce-deploy` 加入家目录属主的组。用 `namei -l <路径>` 检查整条路径权限。

### 3. 脚本只读权限

```bash
sudo -u ce-deploy test -x "${DEPLOY_REPO}/scripts/toolchains/deploy-mlir.sh" || {
  sudo setfacl -m u:ce-deploy:r-x "${DEPLOY_REPO}/scripts"
  sudo setfacl -m u:ce-deploy:r-x "${DEPLOY_REPO}/scripts/toolchains"
  sudo setfacl -m u:ce-deploy:r-x "${DEPLOY_REPO}/scripts/toolchains/deploy-mlir.sh"
  sudo setfacl -m u:ce-deploy:r-- "${DEPLOY_REPO}/scripts/toolchains/lib.sh"
}
```

`ce-deploy` 不需要读取仓库 `.env`，所需变量由 Jenkins 显式传递。

### 4. 安装受限公钥

```bash
sudo install -d -o ce-deploy -g ce-deploy -m 0700 /var/lib/ce-deploy/.ssh

# 将 JENKINS_SOURCE_IP 换成 Jenkins 实际出口 IP，公钥为一行 ed25519 公钥
printf '%s %s\n' \
  'from="JENKINS_SOURCE_IP",no-agent-forwarding,no-X11-forwarding,no-pty,permitopen="127.0.0.1:2223"' \
  'ssh-ed25519 AAAA... jenkins-ce-deploy' |
  sudo tee /var/lib/ce-deploy/.ssh/authorized_keys

sudo chown ce-deploy:ce-deploy /var/lib/ce-deploy/.ssh/authorized_keys
sudo chmod 0600 /var/lib/ce-deploy/.ssh/authorized_keys
```

不能用 `restrict`（会禁止 TCP 转发，ProxyJump 依赖它）；`permitopen="127.0.0.1:2223"` 已把转发限定到 VM SSH 端口。

### 5. 注入 VM 公钥

把同一公钥放到 Compose 可读取的位置，并写入 `.env`：

```bash
install -D -m 0644 jenkins_ce_deploy.pub \
  "${DEPLOY_REPO}/data/ce/keys/jenkins_ce_deploy.pub"
```

```dotenv
CE_VM_SSH_PUBKEY=/home/llm/CompilerExplorer-Deploy/data/ce/keys/jenkins_ce_deploy.pub
```

以后重建 overlay 时 cloud-init 会自动注入。当前运行的 VM 用旧管理密钥手动追加一次：

```bash
cat data/ce/keys/jenkins_ce_deploy.pub |
ssh -i "${CE_VM_SSH_KEY}" -p "${CE_VM_SSH_PORT:-2223}" -o IdentitiesOnly=yes \
  ce@127.0.0.1 '
    set -eu; umask 077
    install -d -m 0700 ~/.ssh
    touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys
    IFS= read -r key
    grep -qxF "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >> ~/.ssh/authorized_keys
  '
```

没有任何旧密钥可用时，只能等新公钥随 overlay 重建注入。

## Jenkins 配置

1. 在安全机器生成密钥：`ssh-keygen -t ed25519 -f jenkins_ce_deploy -C jenkins@ce-deploy -N ''`。
2. Jenkins → Credentials → `SSH Username with private key`：Username `ce-deploy`，ID `ce-deploy-host`，粘贴私钥。
3. 公钥按上文安装到部署机和 VM。

## Jenkinsfile

放在工具链构建仓库根目录，只需替换 Build 阶段的构建命令并核对 `environment` 中的主机与路径。

```groovy
pipeline {
    agent { label 'toolchain-builder' }

    options {
        timestamps()
        disableConcurrentBuilds()              // 发布串行，避免软链竞争
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        DEPLOY_HOST    = 'ce-deploy@poweredger770'
        DEPLOY_REPO    = '/home/llm/CompilerExplorer-Deploy'
        TOOLCHAIN_ROOT = '/home/llm/CompilerExplorer-Deploy/data/ce/compilers'
        INCOMING_ROOT  = '/home/llm/CompilerExplorer-Deploy/data/ce/incoming'
        VM_SSH_PORT    = '2223'
        SSH_OPTS       = '-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new'
        INSTALL_DIR    = "${WORKSPACE}/install"
    }

    stages {
        stage('Build') {
            steps {
                sh '''
                    set -eu
                    # TODO: 换成实际构建命令，把产物安装到 ${INSTALL_DIR}
                    echo "构建产物输出到 ${INSTALL_DIR}"
                '''
            }
        }

        stage('Validate') {
            steps {
                sh '''
                    set -eu
                    test -x "${INSTALL_DIR}/bin/mlir-opt"
                    test -x "${INSTALL_DIR}/bin/mlir-translate"
                    chmod -R a+rX "${INSTALL_DIR}"   # VM 内以只读挂载执行
                '''
            }
        }

        stage('Upload') {
            steps {
                sshagent(credentials: ['ce-deploy-host']) {
                    sh '''
                        set -eu
                        SHORT_COMMIT="$(git rev-parse --short=12 HEAD)"
                        echo "${BUILD_NUMBER}-${SHORT_COMMIT}" > "${WORKSPACE}/.toolchain-build-id"
                        STAGING_DIR="${INCOMING_ROOT}/$(cat "${WORKSPACE}/.toolchain-build-id")"

                        ssh ${SSH_OPTS} "${DEPLOY_HOST}" \
                            "install -d -m 0750 '${STAGING_DIR}'"

                        rsync -aH --no-owner --no-group --delete --partial \
                            -e "ssh ${SSH_OPTS}" \
                            "${INSTALL_DIR}/" "${DEPLOY_HOST}:${STAGING_DIR}/"
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                sshagent(credentials: ['ce-deploy-host']) {
                    sh '''
                        set -eu
                        BUILD_ID="$(cat "${WORKSPACE}/.toolchain-build-id")"
                        ssh ${SSH_OPTS} "${DEPLOY_HOST}" \
                            "CE_COMPILERS_ROOT='${TOOLCHAIN_ROOT}' CE_DEFER_RESTART=1 \
                             '${DEPLOY_REPO}/scripts/toolchains/deploy-mlir.sh' \
                             '${INCOMING_ROOT}/${BUILD_ID}' '${BUILD_ID}'"
                    '''
                }
            }
        }

        stage('Restart CE') {
            steps {
                sshagent(credentials: ['ce-deploy-host']) {
                    sh '''
                        set -eu
                        ssh ${SSH_OPTS} -J "${DEPLOY_HOST}" -p "${VM_SSH_PORT}" \
                            ce@127.0.0.1 \
                            'sudo systemctl restart ce.service && \
                             sudo systemctl is-active ce.service'
                    '''
                }
            }
        }

        stage('Verify') {
            steps {
                sshagent(credentials: ['ce-deploy-host']) {
                    sh '''
                        set -eu
                        ssh ${SSH_OPTS} -J "${DEPLOY_HOST}" -p "${VM_SSH_PORT}" \
                            ce@127.0.0.1 \
                            '/opt/compiler-explorer/mlir-custom/bin/mlir-opt --version | head -1'
                    '''
                }
            }
        }
    }

    post {
        always {
            sshagent(credentials: ['ce-deploy-host']) {
                sh '''
                    if [ -f "${WORKSPACE}/.toolchain-build-id" ]; then
                        BUILD_ID="$(cat "${WORKSPACE}/.toolchain-build-id")"
                        ssh ${SSH_OPTS} "${DEPLOY_HOST}" \
                            "rm -rf -- '${INCOMING_ROOT}/${BUILD_ID}'" || true
                    fi
                '''
            }
            cleanWs()
        }
    }
}
```

要点：

- `CE_DEFER_RESTART=1` 让发布脚本只切换软链，由 `Restart CE` 阶段统一重启 VM 内的 `ce.service`。
- `post.always` 清理部署机上的临时上传目录；`deploy-mlir.sh` 已把内容复制进 `compilers`，删除 staging 不影响已发布版本。
- `StrictHostKeyChecking=accept-new` 适合首次接入，稳定后建议在 agent 上预置 `known_hosts` 并固定指纹。
- 发布其他工具链时复制相应 `deploy-*.sh` 的模式；`deploy-mlir.sh` 要求产物含 `bin/mlir-opt` 与 `bin/mlir-translate`。

## 验证

```bash
# 登录与写权限
ssh -i jenkins_ce_deploy ce-deploy@poweredger770 \
  'id && test -w /home/llm/CompilerExplorer-Deploy/data/ce/incoming'

# 不能列出他人家目录（应 Permission denied）
ssh -i jenkins_ce_deploy ce-deploy@poweredger770 'ls /home/llm'

# ProxyJump 进 VM 并操作 CE
ssh -i jenkins_ce_deploy -J ce-deploy@poweredger770 -p 2223 \
  ce@127.0.0.1 'sudo systemctl is-active ce.service'
```

## 权限边界

| 主体 | 能做什么 | 不能做什么 |
|---|---|---|
| Jenkins 私钥 | 仅存于 Jenkins Credentials | 不在任何服务器磁盘上 |
| `ce-deploy` | 写 `incoming`/`compilers`、执行部署脚本、转发到 `127.0.0.1:2223` | 无 sudo/docker/kvm、不能读取 `/home/llm`、不能写仓库、不能转发到其他地址 |
| VM 内 `ce` | 免密 `restart/status/is-active ce.service` | 无其他 root 权限 |

整个发布只更新工具链目录并重启 `ce.service`，不重建 Docker 镜像、Ubuntu 基础镜像或 CE overlay。
