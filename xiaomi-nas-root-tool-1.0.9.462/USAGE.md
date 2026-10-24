# xiaomi-nas-root.py — 小米智能存储一键 Root & 持久化（固件 1.0.9.x）

基于 UCI Heredoc 注入与动态 aarch64 汇编的新攻击链一键脚本。已在固件版本 `1.0.9.462` 真机上完成全链路回归验证，支持持久化自愈与专用 sudo 运维账号配置。

## 前置条件

1. 本机已安装「小米智能存储」桌面端并**登录过目标 NAS**（客户端证书由 App 生成，脚本自动查找，找不到可用 `--cert-dir` 手动指定）
2. Python 3.9+，安装依赖：`pip install -r requirements.txt`

## 命令行参数

```bash
python xiaomi-nas-root.py <NAS_IP> [选项]

参数说明:
  NAS_IP                  目标 NAS 的局域网 IP 地址 (例如: 192.168.31.24)
  --uid <UID>             指定米家数字 UID (默认自动从客户端证书解析)
  --cert-dir <路径>       指定客户端证书目录 (默认自动搜索 minasCert)
  --shell-port <端口>     临时 socat root shell 监听端口 (默认: 2323)
  --persist               部署 /data/auto_ssh 三重持久化自愈体系 (开机自启、官方 OTA 防清、Crontab 保活)
  --sudo-user <用户名>    在 NAS 上创建持久化 sudo 用户 (家目录建立在 /data/<用户名>，配置免密 sudo)
```

## 典型操作场景

### 场景 1：临时调试（单次会话，用完自动清理）
```bash
python xiaomi-nas-root.py 192.168.31.24
```
- 成功后获得 root 访问权限；
- 清理逻辑自动移除注入的共享与临时文件，不写入持久化启动服务。

### 场景 2：永久开启 SSH 并抵御固件更新（推荐）
```bash
python xiaomi-nas-root.py 192.168.31.24 --persist
```
- 将自愈逻辑固化在 `/data/auto_ssh/keep_ssh.sh`；
- 注册开机自启 Systemd 服务 `/etc/systemd/system/auto-ssh.service`；
- 注册 OTA 升级触发钩子 `/etc/syshotplug/ota/90.persist_ssh.sh`；
- 添加 crontab 每分钟健康检查保活。

### 场景 3：一键配置日常非 root 运维账号
```bash
python xiaomi-nas-root.py 192.168.31.24 --persist --sudo-user phirmu
```
- 部署持久化体系的同时，自动在 `/data/phirmu` 下建立家目录；
- 注入免密 `sudo` 授权与本机 SSH 公钥；
- 将账号自愈规则纳入 `keep_ssh.sh`，确保固件升级后账号与配置不丢失。

---

## 敏感信息与安全处理

- **证书目录**：默认搜索 `%LOCALAPPDATA%\minasCert` 等路径；私钥与证书始终保留在本地。
- **WebDAV 口令**：经由 mTLS 现场提取，**内存即时消费，绝不落盘、绝不打印**。
- **SSH 密钥**：若本地 `~/.ssh/id_ed25519_minas` 不存在则现场生成，私钥只写在本机。
- **临时密码**：步骤②中创建的临时 Samba 共享口令每次运行随机高熵生成，攻击完成后立即销毁。

---

## 攻击链细节（约 1~2 分钟）

| 步骤 | 动作 | 原理与关键攻克点 |
|---|---|---|
| **① mTLS 与凭据** | 证书双向认证 $\rightarrow$ `get_pool_info` | 自动探测服务端真实 CN，解决非主绑定账号导致的 `Hostname mismatch`；提取 WebDAV 凭据（端口 5000）。 |
| **② UCI 注入** | `MKCOL` 换行目录 $\rightarrow$ `add_samba_account` | 利用 `smb_mgr.sh` 的 heredoc 缺陷注入 `force user=root`；随后修复路径至 `/etc`（适配 `etc-<uid>` 共享名）。通过纯 Python SMB 实现跨平台免特权直写。 |
| **③ 汇编触发** | Keystone 汇编 .so $\rightarrow$ `ld.so.preload` | 现场汇编 aarch64 ELF 共享库；等待 cron 每分钟计划任务加载执行；动态通过 `mount --bind` 绕过受限 `mi-shell`，开放标准 Bash。 |

---

## 产物与访问连接

连接已就绪的 NAS 终端：

```bash
# 1. 使用普通 sudo 账号登录 (若指定了 --sudo-user)
ssh -i ~/.ssh/id_ed25519_minas phirmu@<NAS_IP>

# 2. 直接以 root 登录
ssh -i ~/.ssh/id_ed25519_minas root@<NAS_IP>

# 3. 连入紧急交互 Shell (仅脚本执行等待期间或应急使用)
nc <NAS_IP> 2323
```

---

## 常见排障 (Troubleshooting)

1. **报错 `no working server CN`**：
   - 检查电脑是否已在局域网内与目标 NAS 保持联通（`ping <NAS_IP>`）；
   - 确认桌面端 App 登录过该设备，证书文件未被移动或损坏。
2. **报错 `SMB write failed`**：
   - 确认本地已安装 `smbprotocol`（`pip install smbprotocol[kerberos]`）；
   - 检查 NAS 的 445 端口是否受防火墙阻挡。
3. **SSH 登录后出现 `[MINAS]` 且命令不可用**：
   - 这是小米定制 Dropbear 的硬编码行为；
   - 运行 `mount --bind /bin/bash /usr/sbin/mi-shell` 并将 `/usr/bin/bash` 写入 `/etc/shells` 即可彻底解除。脚本自带该修复逻辑。
