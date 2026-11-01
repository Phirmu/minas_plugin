# Xiaomi NAS (小米智能存储) 机器环境档案

本文档记录了这台小米智能存储（Xiaomi NAS）的硬件架构、操作系统、内核特性、存储布局、用户权限体系与网络端口映射细节。

---

## 1. 硬件架构与系统环境

| 项目 | 参数 / 特征 | 说明 |
| :--- | :--- | :--- |
| **设备型号** | 小米智能存储 (Xiaomi NAS) | 双盘位 / 多盘位网络存储设备 |
| **SoC 芯片** | Realtek RTD1619B | 4 核心 ARM Cortex-A55 @ aarch64 |
| **内存 (RAM)** | 4 GB LPDDR4 | 无 Swap 分区，高负载需关注内存溢出 |
| **操作系统** | Poky (Yocto Project Reference Distro) 5.0.3 (scarthgap) | 嵌入式 Linux 发行版，无完整 Debian/Ubuntu 包管理环境 |
| **内核版本** | Linux `6.6.35-yocto-standard` (aarch64) | 抢占式内核 (`PREEMPT`) |
| **C 运行时 (libc)** | GNU C Library (glibc) 2.39 | **警告**：切勿通过 `apt` 覆盖升级底层 glibc，以免破坏系统关键守护进程 |
| **Node.js 环境** | Node.js v26.13.0 (ESM/CJS) | 部署于 `/data/phirmu/.nvm/versions/node/v26.13.0/` |
| **Python 环境** | Python 3.12 (内置) | 系统默认 `/usr/bin/python3` |

### 内核机制与沙箱限制
- **EROFS 只读根目录**：系统根目录 `/` 为 EROFS（Enhanced Read-Only File System），普通进程对 `/`、`/usr`、`/etc` 等无法直接写操作（部分通过 overlayfs 挂载）。
- **Bubblewrap (bwrap) 缺失**：系统未预装 `bwrap` 依赖。
- **Landlock 内核限制**：内核编译虽带有 `CONFIG_LSM="landlock,..."`，但实际运行中未开启 Landlock ABI 强制隔离（`landlock-run --probe` 返回 125 `unusable`）。
- **沙箱运行原则**：所有执行器（如 DSH Bash/Terminal）在小米 NAS 上必须配置为免沙箱回退模式（`danger-full-access` / `unconfined`），否则会因 `SANDBOX_UNAVAILABLE` 导致命令执行失败。

---

## 2. 存储布局与文件系统

```
/
├── / (EROFS - 只读系统根目录)
├── /data (ext4 加密分区 /dev/mapper/data_sec, ~10GB)
│   ├── /data/phirmu/           # phirmu 用户主目录 (nvm, npm 缓存, DSH 代码与配置)
│   ├── /data/plugin/           # 插件系统核心 (各用户 .list 清单, www 软链, 图标)
│   ├── /data/backup/plugins/   # 插件重启自愈脚本与备份
│   ├── /data/docker/           # Docker 引擎与 CLI 二进制
│   └── /data/plugincenter_shield/ # 阻止小米云端重置清空自制插件的防护守护
├── /home (overlay 挂载于 /data/home)
│   ├── /home/u2469233489/      # 管理员用户 Home (包含 plugin/ 插件实际目录)
│   └── /home/u2167447919/      # 普通用户 Home
└── /nas/pool0 (cfs / btrfs 存储池, ~7.3TB)
    ├── /nas/pool0/u2469233489/data/ # 用户个人存储根目录
    │   └── ai/                 # AI / DSH 工作区根目录 (chmod 2775, chown :naspub)
    └── /nas/pool0/u2167447919/data/ # 另一用户个人存储根目录
        └── ai/                 # AI 工作区根目录
```

### 关键路径说明
- **AI 共享工作区**：`/nas/pool0/$USER/data/ai`
  - 目录权限：`drwxrwsr-x`（SGID `2775`），所属组为 `naspub`。
  - 作用：确保不同用户及 DSH 服务进程创建的新文件、目录自动继承 `naspub` 组并拥有组写权限。
- **NPM / NPX 缓存目录**：`/data/phirmu/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai/`
  - DSH 的所有后端与前端核心代码均部署于此。

---

## 3. 用户与组权限体系

小米 NAS 采用多用户隔离架构，米家账号绑定后会分配 `u<UID>` 格式的独立系统账号：

| 用户名 | UID | 身份说明 | 主要所属组 | 备注 |
| :--- | :--- | :--- | :--- | :--- |
| `root` | `0` | 超级管理员 | `root` (0) | 用于底层维护、SSH、systemd 部署 |
| `u2469233489` | `8464` | 主管理员用户 (Owner) | `u2469233489`, `nasadm`, `naspub` | 拥有 NAS 控制台管理员权限 |
| `u2167447919` | `10371` | 共享/普通用户 | `u2167447919`, `naspub` | 普通家庭成员 |
| `phirmu` | `10372` | 专职后台服务账号 | `phirmu`, `naspub`, `nasadm`, `docker`, `u2469233489`, `u2167447919` | 专用于托管运行 DSH 与独立后台进程 |

### 核心用户组
- **`naspub` (GID: 902)**：公共共享组。所有 NAS 用户及 `phirmu` 均为成员。AI 目录与跨用户文件交互的推荐组。
- **`nasadm` (GID: 901)**：NAS 管理组。包含管理员用户及 `phirmu`。
- **`docker` (GID: 999)**：Docker 容器管理组。
- **权限规范**：后台服务运行的 systemd 需显式声明：
  ```ini
  User=phirmu
  Group=naspub
  SupplementaryGroups=naspub nasadm u2469233489 u2167447919 docker
  UMask=0002
  ```

---

## 4. 网络架构与监听端口

- **NAS 局域网 IP**：`192.168.31.23`（网关：`192.168.31.1`）
- **核心端口映射与分工**：

| 端口 | 监听范围 | 协议 / 进程 | 用途说明 |
| :--- | :--- | :--- | :--- |
| `22` | `0.0.0.0` | SSH (Dropbear/OpenSSH) | root 终端登录通道 |
| `2323` | `0.0.0.0` | socat (mTLS) | 救砖与紧急 Root Shell 通道 |
| `5000` | `0.0.0.0` | Nginx (HTTP) | 小米智能存储 HTTP 基础 Web 控制台 |
| `5005` | `0.0.0.0` | Nginx (HTTPS) | WebDAV 及插件通用安全反代入口 |
| `5006` | `0.0.0.0` | Nginx (HTTPS) | 应用中心与管理服务控制端口 |
| `3080` | `127.0.0.1` | Node.js (dsh) | DeepSeek Harness Web 服务（由 Nginx 反代） |
| `7681` | `127.0.0.1` | ttyd (aarch64) | Web 终端服务（由 Nginx 反代） |
| `8080` | `127.0.0.1` | Docker (motrix-server) | Motrix 下载管理容器 RPC / Web |
| `9301` | `127.0.0.1` | Python (sysmon) | 系统状态插件 HTTP API |
| `9302` | `127.0.0.1` | Python (dockerctl) | Docker 控制台插件 HTTP API |
| `9303` | `127.0.0.1` | Python (pcbackup) | PC 增量备份插件 HTTP API |
| `445` / `139` | `0.0.0.0` | smbd (Samba) | 局域网 Windows 共享服务 |
