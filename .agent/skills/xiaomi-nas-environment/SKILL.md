---
name: xiaomi-nas-environment
description: >-
  Reference and operation manual for the Xiaomi NAS hardware, OS, network, users/permissions,
  storage layout, and plugin architectures (DSH, ttyd, motrix, dockerctl, pcbackup, sysmon).
  Use this skill when developing, debugging, deploying, or managing plugins and services on the Xiaomi NAS.
---

# Xiaomi NAS (小米智能存储) 机器环境与插件架构速查指南

本 Skill 汇总了小米智能存储（Xiaomi NAS）设备的硬件指标、操作系统、存储挂载布局、多用户权限隔离体系，以及全部 6 款自制插件的关键配置与运维 Runbook。

---

## 1. 核心环境速览 (Quick Reference)

### 硬件与系统概览
| 指标 | 规格 / 属性 | 说明 |
| :--- | :--- | :--- |
| **设备 CPU** | Realtek RTD1619B (4-Core A55 @ aarch64) | 64 位 ARM 架构 |
| **运行内存** | 4 GB LPDDR4 (无 Swap) | 需控制服务内存溢出 |
| **操作系统** | Poky (Yocto) 5.0.3 (scarthgap) | Linux 6.6.35 抢占式内核 |
| **根文件系统** | EROFS (只读 SquashFS) | 根目录只读，不能在 `/` 写入或 fsync |
| **持久存储** | `/data` (10G 加密) + `/nas/pool0` (7.3T 存储池) | `/data` 存程序，`/nas` 存大文件 |
| **关键限制** | **无 bwrap，内核关闭 Landlock ABI** | 沙箱命令必须采用 `unconfined` 回退 |

### 用户与组权限
| 标识 | ID | 角色 | 关键成员 / 权限说明 |
| :--- | :--- | :--- | :--- |
| **`root`** | 0 | 超级管理 | SSH 维护与系统底层控制 |
| **`u2469233489`** | 8464 | 主账号 (Owner) | 米家绑定管理账号，所属组 `nasadm`, `naspub` |
| **`u2167447919`** | 10371 | 普通共享账号 | 家庭共享账号，所属组 `naspub` |
| **`phirmu`** | 10372 | 后台守护账号 | 托管运行 DSH，拥有 `naspub`, `nasadm`, `docker` 等附加组 |
| **`naspub`** | 902 | 公共协作组 | AI 目录 (`/nas/pool0/*/data/ai`) 归属组 (SGID `2775`) |

---

## 2. 插件矩阵 (Plugins Matrix)

| 插件标识 | ID | 服务端口 | 运行形态 | 核心功能与关键配置 |
| :--- | :--- | :--- | :--- | :--- |
| **`dsh`** | 93 | `3080` | Node.js (Cordis) | DeepSeek Harness Web，集成沙箱回退、透明免密 Cookie、AI 工作区 |
| **`ttyd`** | 94 | `7681` | aarch64 静态二进制 | 轻量 Web 原生终端，免容器，集成 trzsz 极速传文件 |
| **`motrix`** | 95 | `8080` | Docker 容器 | Motrix 下载管理，Unix socket 反代，内置 Docker 出站 NAT 修复 |
| **`pcbackup`** | 96 | `9303` | Python HTTP | PC 增量备份，8MiB 分块断点续传，`.del` 软删除保护，清单双写 |
| **`dockerctl`**| 97 | `9302` | Python HTTP | 完整 Docker 控制台，容器/镜像/存储卷/网络管理，Compose YAML 编排 |
| **`sysmon`**   | 98 | `9301` | Python HTTP | 系统状态监控仪表盘，实时 CPU、内存、SMART 温度、风扇、Docker 状态 |

---

## 3. 详细专题参考 (References)

深入开发、配置修补或故障排查时，请阅读对应的参考专题：

- [机器硬件与系统完整档案](./references/machine_profile.md)：硬件参数、内核特性、分区挂载点、用户权限分配详情。
- [插件系统开发与运行规范](./references/plugin_framework.md)：目录组织、INFO 结构、.list 注册清单、Nginx 反代规则与防清空 Shield 守护。
- [DSH 架构与真机修补详解](./references/dsh_architecture.md)：Cordis 架构、`cordis.patch.yml`、免沙箱执行、附件上传修复与工作区规划。
- [各插件关键配置与架构参考](./references/plugins_reference.md)：dockerctl、motrix、pcbackup、sysmon、ttyd 的详细设计参数与配置。
- [插件部署与排错手册](./references/deployment_guide.md)：`deploy-plugins.py` 统一部署命令、单插件部署与高频问题解决 Runbook。

---

## 4. 常用操作与巡检脚本

### 环境健康巡检
运行技能内置的检查脚本快速获取 NAS 当前软硬件及各插件服务健康状态：
[check_nas_status.sh](./scripts/check_nas_status.sh)

```bash
# 在本地直接通过 SSH 远程执行
ssh -n root@192.168.31.23 "sh -s" < .agent/skills/xiaomi-nas-environment/scripts/check_nas_status.sh
```

### 部署插件常用命令
```bash
# 列出可部署插件
python deploy-plugins.py --list

# 部署 DeepSeek Harness (dsh)
python deploy-plugins.py --select dsh

# 部署全部插件
python deploy-plugins.py --select all
```

---

## 5. 开发与修改黄金守则 (Golden Rules)

1. **绝对不要通过 `apt` 升级基础库**：Yocto 系统的 `libc6` 与 Debian 仓库存在 ABI 差异，覆盖升级极易导致底层进程崩溃。
2. **沙箱强制回退**：在编写或集成涉及终端执行的工具时，不要假设底层支持 `bwrap` 或 `Landlock`，必须提供 unconfined 直接执行路径。
3. **保持组写权限**：写入 `/nas/pool0/` 下的共享文件，服务进程必须声明 `UMask=0002` 并以 `naspub` 组协同。
4. **所有修补必须幂等**：`deploy.sh` 中的正则替换与配置写入必须具有幂等防护（如使用单行 Guard 注释），防止重复部署产生语法错误。
