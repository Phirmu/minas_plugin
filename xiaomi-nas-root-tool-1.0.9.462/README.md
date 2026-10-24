# xiaomi-nas-root-tool-1.0.9.462 — 小米智能存储（RP05）固件 1.0.9.x Root 与 SSH 持久化工具

旧工具（kid0114/xiaomi-nas-ssh-root-tool）依赖的 WebDAV 视频分段 shell 注入在固件 1.0.9.462 中已被修补。本工具基于研究出的全新攻击链（uci heredoc 注入）实现，并在真机环境下完成全流程验证，同时攻克了 mTLS UID 不匹配、Samba 命名重变、受限 `mi-shell` 拦截、官方 OTA 定点清理等关键卡点。

实测固件：`1.0.9.462.F24C26D24-REL` (支持小米智能存储 RP05 全系 1.0.9.x 固件)。

## 目录结构

| 文件 / 目录 | 说明 |
|---|---|
| `xiaomi-nas-root.py` | 一键 Root 与持久化脚本（全自动 mTLS 证书探测 / 纯 Python SMB2/3 免特权直写 / mi-shell 限制绕过 / 持久化与 Sudo 用户部署） |
| `USAGE.md` | 详细使用说明（参数、攻击链细节、排障指南） |
| `技术复盘.md` | 技术复盘文档（链路原理、各步骤踩坑及真机修复方案） |
| `SKILL.md` / `skills/` | Antigravity AI Agent 技能固化文档：<br>• `xiaomi-nas-root`: Root、mTLS、mi-shell 绕过与自愈体系<br>• `xiaomi-nas-storage-ops`: EROFS/OverlayFS/CFS 挂载架构、bind-mount 技巧与用户组权限运维 |
| `scripts/` | 固化在 `/data/auto_ssh/` 中的自愈保活脚本及服务定义模板 |
| `requirements.txt` | Python 依赖（`keystone-engine`、`smbprotocol`） |

## 快速开始

```bash
# 安装依赖
pip install -r requirements.txt

# 1. 基础获取 Root (单次会话，用完自动清理)
python xiaomi-nas-root.py <NAS_IP>

# 2. 获取 Root 并开启开机自启与官方 OTA 防清理自愈
python xiaomi-nas-root.py <NAS_IP> --persist

# 3. 获取 Root、开启持久化自愈，并创建专用 sudo 用户 (推荐)
python xiaomi-nas-root.py <NAS_IP> --persist --sudo-user phirmu
```

前置条件：本机已安装「小米智能存储」桌面端并**登录过目标 NAS**（证书目录脚本会自动在 `%LOCALAPPDATA%\minasCert` 等路径搜索）。

## 核心特性

1. **证书真实 CN 自动探测**：自动识别客户端证书与服务端证书所有者 UID 不一致的情况，解决多账号与共享成员 mTLS 握手报错。
2. **纯 Python SMB 访问**：借助 `smbprotocol` 实现原生 SMB2/SMB3 文件读写，Linux/WSL 下无需 `mount.cifs` 或 root 挂载权限。
3. **解除 `mi-shell` 受限终端**：通过内核 bind-mount 动态覆盖小米定制 Dropbear 中硬编码的受限 Shell，开放标准 Bash。
4. **三重自愈防御体系 (`--persist`)**：针对小米官方 OTA 脚本在更新时定点删除 `/home/rootx` 的机制，将自愈脚本与公钥沉淀至官方绝对不擦除的 `/data/auto_ssh/`，配合 Systemd、OTA Hook、Crontab 实现重启与 OTA 免疫。
5. **持久化 Sudo 用户创建 (`--sudo-user`)**：自动在持久化分区 `/data/<user>` 创建家目录、注入公钥并配置免密 `sudo`。
