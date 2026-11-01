# 各插件关键配置与架构参考 (Plugins Reference)

本文档归纳了 Xiaomi NAS 上除 DSH 以外的其他 5 个关键插件的配置参数、系统服务、架构设计与运维考量。

---

## 1. Docker 控制台 (dockerctl)

- **插件 ID**：`97` | **版本**：`1.0.0` | **本地端口**：`9302`
- **后台服务**：Python 3 轻量 HTTP 服务 (`src/files/httpd.py`)
- **Docker 交互**：通过 `/var/run/docker.sock` Unix Domain Socket 直接与 Docker Daemon 通信。
- **核心模块**：
  1. **概览**：运行中/停止容器数、镜像占用、数据卷与网络统计。
  2. **容器管理**：列表、启停/重启/强制删除、实时日志流、端口映射与目录挂载。
  3. **镜像仓库**：本地镜像检索、一键拉取（优先 GHCR / 镜像加速）、清理无标签镜像。
  4. **一键部署**：支持可视化表单部署（填写环境变量、挂载卷、网络）及原生 Docker Compose YAML 编排。
  5. **存储与网络**：Named Volume 及自定义 Bridge/Macvlan 网络生命周期管理。

---

## 2. Motrix 下载管理器 (motrix)

- **插件 ID**：`95` | **版本**：`0.3.27` | **本地端口**：`8080`
- **形态**：Docker 容器 (`ghcr.io/agalwood/motrix-server:2.0.0-beta.40`)
- **数据与持久化**：
  - 数据目录：`/data/motrix-server/data/`
  - 默认下载目录：`/nas/pool0/u<UID>/data/motrix-downloads`（限制只在当前用户 data 目录内）
  - 认证文件：`/data/motrix-server/data/operator-token`（在 NAS 端代理自动注入，绝不暴露给前端浏览器）
- **关键运维细节**：
  - **Docker 容器出站 NAT 修复**：小米 NAS 的 Docker 桥接网络默认缺少出站地址伪装（MASQUERADE），导致容器内无法解析公网 DNS 或下载。部署脚本会在 `motrix-restore.service` 中自动注入针对该容器桥接地址的 iptables 出站转换规则。
  - **安全反代**：`motrix-web-proxy.service` 监听内部 Unix socket，仅允许受信任的 Nginx 插件路径转发。

---

## 3. PC 增量备份 (pcbackup)

- **插件 ID**：`96` | **版本**：`1.3.0` | **本地端口**：`9303`
- **形态**：Python HTTP Server (`files/httpd.py`)
- **备份目标目录**：`/nas/pool0/u<UID>/data/PCBackup/`
- **核心特性与机制**：
  1. **分块断点续传**：固定 8 MiB 块大小传输，中断后自动从临时 `.pcbp.part` 文件偏移继续，避免整文件重传。
  2. **软删除保护 (`.del`)**：PC 端删除的文件，NAS 端只打上 `<原名>.del` 标记，绝不真正抹除数据。
  3. **删除激增熔断**：单次任务删除比例超过清单 20% 且 ≥10 个文件时，必须由用户手动在 Web 勾选“强制执行”，防止电脑选错源目录导致灾难性误标。
  4. **清单双写**：同步记录于插件内部目录与目标备份数据目录根部，抵御 NAS 固件升级恢复。
  5. **默认排除规则**：内置过滤 `node_modules/`、`.venv/`、`__pycache__/`、`*.pyc`、`test-results/`、`coverage/` 等衍生开发文件。

---

## 4. 系统状态仪表盘 (sysmon)

- **插件 ID**：`98` | **版本**：`1.0.0` | **本地端口**：`9301`
- **形态**：Python HTTP API (`files/httpd.py`) + CGI / Web UI
- **采集指标**：
  - CPU 使用率（按核心与整体）及温度传感器
  - 内存占用率（Buffers / Cached / Available）
  - 存储池挂载状态与 SMART 运行温度、风扇转速
  - 网络实时进出流量统计
  - 运行中 Docker 容器资源占用

---

## 5. Web 终端 (ttyd)

- **插件 ID**：`94` | **版本**：`1.7.7` | **本地端口**：`7681`
- **形态**：原生 aarch64 静态二进制 (`/data/ttyd/ttyd`)
- **systemd 单元**：`/etc/systemd/system/ttyd.service`
  ```ini
  ExecStart=/data/ttyd/ttyd -p 7681 -i 127.0.0.1 -W /bin/bash
  ```
- **核心特性**：
  - 零容器依赖，CPU 占用极低（仅几兆内存）。
  - 支持完整 xterm.js 终端、ANSI 256/真彩色、鼠标滚动与窗口自适应重排。
  - 集成 trzsz / lrzsz 拖拽文件极速传输能力。
  - 通过 Nginx 的 WebSocket `Upgrade: $http_upgrade` 进行流式长连接转发。
  - 具备开机自愈单元 `/etc/systemd/system/ttyd-restore.service`。
