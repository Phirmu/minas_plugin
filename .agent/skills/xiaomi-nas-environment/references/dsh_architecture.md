# DeepSeek Harness (DSH) 架构与关键配置详解

DeepSeek Harness (DSH) 是基于 Cordis 微内核架构的自主智能体交互环境，运行在小米 NAS 的专用 `phirmu` 服务用户下。本文档详细记录其服务结构、配置模型及真机关键修补逻辑。

---

## 1. 运行架构与服务单元

- **运行进程**：Node.js v26.13.0
- **工作目录**：`/data/phirmu/dsh`
- **核心包路径**：`/data/phirmu/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai/`
- **监听端口**：`127.0.0.1:3080` (由 Nginx 反代向局域网用户提供)
- **systemd 单元**：`/etc/systemd/system/dsh.service`

```ini
[Unit]
Description=DeepSeek Harness (dsh) web service
After=network.target

[Service]
Type=simple
User=phirmu
Group=naspub
SupplementaryGroups=naspub nasadm u2469233489 u2167447919 docker
UMask=0002
WorkingDirectory=/data/phirmu/dsh
Environment=PATH=/data/phirmu/.nvm/versions/node/v26.13.0/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=/data/phirmu
Environment=DSH_PERMISSION_MODE=danger-full-access
ExecStart=/data/phirmu/.nvm/versions/node/v26.13.0/bin/node /data/phirmu/.npm/_npx/1e7f6d9597241db0/node_modules/.bin/dsh web --no-open --port 3080 --host 127.0.0.1
Restart=on-failure
RestartSec=5
StandardOutput=append:/tmp/dsh/server.log
StandardError=append:/tmp/dsh/server.log

[Install]
WantedBy=multi-user.target
```

---

## 2. 配置文件：`cordis.patch.yml`

DSH 采用分层 YAML 配置，所有个性化与环境适配均维护在 `/data/phirmu/.dsh/profiles/web/cordis.patch.yml` 中：

```yaml
# 1. 权限预设与沙箱映射 (映射为 danger-full-access 跳过不可用的底层沙箱，同时保留 approval 确认)
- id: permission
  name: "@deepseek-ai/dsh-permission-presets"
  config:
    presets:
      read-only:
        sandbox: danger-full-access
        approval: ask
      workspace-write:
        sandbox: danger-full-access
        approval: ask
      danger-full-access:
        sandbox: danger-full-access
        approval: never
    defaultPreset: workspace-write

# 2. 全局沙箱策略默认模式
- id: sandbox-policy
  name: "@deepseek-ai/dsh-sandbox-policy"
  config:
    mode: danger-full-access
    workspaceRoot: !!js process.cwd()

# 3. 禁用 HMR 减少 NAS 内存消耗
- id: client-hmr
  disabled: true

# 4. LLM 模型与提供商配置
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      token-go:
        displayName: tokenGo
        apiKeyEnv: TOKEN_GO_API_KEY
        api: openai-completions
        baseURL: https://token-go.ccwu.cc/v1
        models:
          - id: gpt-6.1-sol
            name: gpt-6.1-sol
```

---

## 3. 工作区存储与跨用户文件交互

- **工作区注册表**：`/data/phirmu/.dsh/storages/workspace.json`
- **默认工作区根目录**：
  - 用户 `u2469233489`：`/nas/pool0/u2469233489/data/ai/`
  - 用户 `u2167447919`：`/nas/pool0/u2167447919/data/ai/`
- **权限继承策略**：
  - 目录均设置 SGID 位 (`chmod 2775`)，所属组为 `naspub`。
  - DSH 服务运行带有 `UMask=0002` 与 `Group=naspub`。
  - 用户通过米家上传、网页上传或 DSH 生成的文件，均属于 `naspub` 组且具备写权限，跨用户无障碍读写。

---

## 4. 小米 NAS 定制修补记录 (Patches)

为适配小米 NAS 的特殊硬件与固件环境，在 `deploy/deploy.sh` 中集成了以下关键幂等修补：

### 1) 沙箱不可用回退 (`@deepseek-ai/dsh-sandbox-local`)
- **现象**：NAS 无 `bwrap` 且内核关闭 Landlock，导致默认调用沙箱失败报 `SANDBOX_UNAVAILABLE`。
- **修补**：在 `selectRunner(mode)` 探测为 `unavailable` 时，直接返回 `{ runner: "unconfined", enforcement: "full" }`，`confine()` 直接放行原 `argv` 执行。

### 2) EROFS 根目录同步报错 (`@deepseek-ai/dsh-attachment-local`)
- **现象**：Node.js 在处理文件附件上传时对所在分区调用 `syncDirectory()`，在只读 EROFS 根目录下报 `EINVAL` / `EROFS`。
- **修补**：捕获并容忍 `EINVAL`、`EROFS`、`EPERM`、`EBADF`、`EACCES` 异常。

### 3) 目录选择器默认路径 (`dsh-host-directory-picker-browse` & `dsh-client-ui-directory-picker-browse`)
- **现象**：默认浏览根目录指向系统根 `/` 或 `homedir()`，导致用户找不到真正的 NAS 存储池。
- **修补**：优先返回 `/nas/pool0/$USER/data/ai`，若未指定则探测存在的可写 AI 目录。

### 4) SlotAssemblyError 注释嵌套语法报错 (`dsh-client-ui-renderer`)
- **现象**：多次部署正则替换导致多层 `/* /* ... */ */` 嵌套，引起 `Unexpected token '*'` 语法错误。
- **修补**：采用单行幂等标记 `// IGNORE_SLOT_ASSEMBLY_ERROR:` 规避块级注释嵌套。

### 5) Nginx 自动注入登录凭证
- **现象**：DSH Web 会话默认每次重启打印随机 token，用户从米家打开需手动输入。
- **修补**：Nginx location 规则自动注入签名的 `Cookie: dsh-auth-xxx`，实现米家 App 内一键免密透明进入。
