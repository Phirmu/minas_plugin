# 插件部署流程与排错手册 (Deployment Guide)

本文档介绍在本地机器与 Xiaomi NAS 之间进行代码打包、验证、部署与故障排查的标准操作流程。

---

## 1. 自动化统一部署流程

代码仓库根目录下提供了跨平台、集成化的 Python 部署工具 `deploy-plugins.py`。

### 1) 配置文件 (`deploy-config.json`)
推荐在仓库根目录创建 `deploy-config.json`（已被 `.gitignore` 忽略）：

```json
{
  "host": "192.168.31.23",
  "uid": "2469233489",
  "ssh_key": "",
  "user": "root",
  "port": 22,
  "transport": "auto",
  "channel": "ssh"
}
```

### 2) 常用部署命令

- **列出所有已就绪插件（无需连接 NAS）**：
  ```bash
  python deploy-plugins.py --list
  ```
- **部署单个插件（例如部署 DSH）**：
  ```bash
  python deploy-plugins.py --select dsh
  ```
- **部署多个指定插件**：
  ```bash
  python deploy-plugins.py --select dsh,ttyd,dockerctl
  ```
- **全部部署**：
  ```bash
  python deploy-plugins.py --select all
  ```
- **自动化测试**：
  ```bash
  python -X utf8 -m unittest discover -s tests -v
  ```

---

## 2. 单插件独立部署 (SSH Direct)

当需要临时更新或调试单个插件时，可以直接在 NAS 上执行该插件自带的 `deploy.sh`：

```bash
# 语法: sh deploy.sh <数字UID> [NAS_IP]
# 例如在 NAS root 下执行：
cd /home/u2469233489/plugin/dsh/deploy
sh deploy.sh 2469233489 192.168.31.23
```

---

## 3. 常见故障排查 Runbook

### 1) DSH 报 `SANDBOX_UNAVAILABLE` 导致无法执行命令
- **原因**：会话试图调用 `workspace-write` 沙箱模式，但底层 Yocto 系统无 `bwrap` 且 Landlock 被禁用。
- **排查**：
  1. 检查 `/data/phirmu/.dsh/profiles/web/cordis.patch.yml` 中 `permission.presets` 是否将 `sandbox` 设为 `danger-full-access`。
  2. 检查 `/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-sandbox-local/lib/index.js` 是否已修补 `selectRunner` 回退至 `unconfined`。
  3. 执行 `systemctl restart dsh.service` 重启服务生效。

### 2) 前端提示 `Failed to load plugins` 或控制台报 SyntaxError
- **原因**：多次脚本正则替换导致 `SlotAssemblyError` 被嵌套多层 `/* /* ... */ */` 从而触发 JS 语法错误。
- **排查**：
  1. 运行 `node --check /data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-client-ui-renderer/lib/client.js`。
  2. 确保替换为单行 `// IGNORE_SLOT_ASSEMBLY_ERROR:` 守卫。

### 3) 上传文件附件报错 `EINVAL` 或 `EROFS`
- **原因**：Node.js 附件模块在只读 EROFS 根目录下执行了 `syncDirectory()`。
- **排查**：确认 `@deepseek-ai/dsh-attachment-local` 中的 `syncDirectory` 已添加对 `EROFS` / `EINVAL` 的捕获忽略。

### 4) 重启 NAS 后自制插件在米家 App 中丢失
- **原因**：小米官方应用中心守护进程（`minas.plugin_center.service`）从云端覆盖了本地 `.list` 清单。
- **排查**：
  1. 检查 `systemctl status plugincenter-shield.service` 是否为 active。
  2. 检查各插件自愈单元：`systemctl status dsh-restore.service`。
  3. 手动触发恢复：`sh /data/backup/plugins/dsh/restore.sh`。

### 5) 局域网无法通过 SSH 连接，提示 Dropbear Exec 异常
- **解决**：改用备用救砖通道 `socat`（mTLS 加密直连 2323 端口）：
  ```bash
  python deploy-plugins.py --channel socat --select dsh
  ```
