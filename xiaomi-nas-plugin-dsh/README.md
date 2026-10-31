# 小米 NAS DeepSeek Harness (dsh) Web 插件

为小米智能存储（Xiaomi NAS）提供的 DeepSeek Harness Web 交互控制台插件。

## 特性

- **智能体 Web 控制台**：直观在米家 App 或浏览器中使用 DeepSeek Harness 编写代码、执行工作流与多 Agent 协同。
- **动态认证透明桥接**：自动关联 NAS 本地 dsh 凭证体系，免去频繁查找与输入临时 launch token。
- **全链路代理与 WebSocket 支撑**：Nginx 原生反代，支持长连接、流式输出与 RPC 交互。
- **systemd 托管与自愈恢复**：集成系统服务，崩溃自动重启，NAS 固件升级或重启后自动恢复。

## 部署

通过仓库统一入口部署：

```bash
python deploy-plugins.py --select dsh
```

或手动执行部署脚本：

```bash
sh deploy/deploy.sh <NAS_UID>
```
