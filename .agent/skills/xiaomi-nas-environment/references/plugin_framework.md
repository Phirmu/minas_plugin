# 小米 NAS 插件系统开发与运行规范 (Plugin Framework)

小米智能存储采用了一套轻量、模块化、多用户的插件管理架构。本文档详述插件的生命周期、注册表规范、反向代理注入以及防重置自愈机制。

---

## 1. 插件结构规范

每个插件目录（如 `xiaomi-nas-plugin-<name>`）遵循标准布局：

```text
xiaomi-nas-plugin-<name>/
├── INFO                     # 核心元数据（JSON 格式）
├── scripts/
│   └── control              # 生命周期钩子脚本 (preinstall/postinstall/start/stop 等)
├── deploy/
│   ├── deploy.sh            # NAS 端直接部署脚本
│   ├── package-and-upload   # 打包与上传部署辅助
│   ├── list-entry.json      # .list 注册条目模板
│   └── nginx-location.conf  # Nginx 反代配置规则模板
└── src/ (或根目录)
    ├── files/               # 后端可执行程序 (Python httpd.py / 二进制 / node)
    └── ui/                  # 前端静态资源 (HTML, JS, CSS, 图标, CGI 脚本)
```

### INFO 元数据字段解析

```json
{
  "plugin": "dsh",           // 插件唯一标识符，匹配目录名 xiaomi-nas-plugin-<plugin>
  "name": "DeepSeek Harness",// 界面显示名称
  "id": 93,                  // 插件数字 ID（建议 90~99 避开系统保留段）
  "version": "1.0.0",        // 语义化版本号
  "tags": ["tool", "ai"],    // 分类标签
  "desc": "功能简要描述",
  "developer": "phirmu",
  "publisher": "minas",
  "port": "3080",            // 插件主服务监听端口
  "type": "standard",        // 插件类型 (standard / local)
  "forceupgrade": false,
  "ext": {}
}
```

---

## 2. 插件注册与文件系统映射

### 1) 注册表清单 (`/data/plugin/<USER_NAME>.list`)
- 每个 NAS 账户拥有独立的插件列表文件，如 `/data/plugin/u2469233489.list`。
- 格式为 JSON 对象，包含 `plugin_list` 数组。
- 部署脚本必须通过幂等方式检测是否存在相同 `plugin` 字段，已存在则更新，不存在则追加。

### 2) Web 静态资源与软链
- **Web 访问根目录**：`/data/plugin/www/<USER_NAME>/<PLUGIN_NAME>`
  - 通常软链接到实际安装目录的 `ui` 或前端构建产物：
    `ln -snf /home/<USER_NAME>/plugin/<PLUGIN_NAME>/src/ui /data/plugin/www/<USER_NAME>/<PLUGIN_NAME>`
- **图标路径**：`/data/plugin/www/icon/<PLUGIN_NAME>.icon`（PNG 格式，尺寸建议 300×300）。

---

## 3. Web 访问与 Nginx 反向代理

小米 NAS 对插件的 HTTP 请求处理分为两种模式：

### 模式 A：原生 CGI 网关 (`plugin.cgi`)
- 适用于轻量 Python 或 Shell 生成的动态页面。
- 请求走 `/plugin/<UID>/<plugin>/`，经由 FastCGI (`/var/run/fcgi.sock`) 派发给 `/usr/bin/plugin.cgi` 执行。

### 模式 B：独立守护进程 + Nginx 直通反代 (推荐高性能模式)
- 适用于 Node.js、Go、Python 常驻 HTTP 服务（如 DSH、ttyd、motrix）。
- 需向 `/etc/nginx/conf.d/luci/plugincenter.conf` 头部注入专属 `location` 规则块：

```nginx
# === 示例：ttyd / dsh 高性能反代配置 ===
location ~ ^(?:/[a-zA-Z]:)?/plugin/u?(?:2469233489|[0-9]+)/dsh/(?:index\.html)?$ {
  rewrite ^ / break;
  proxy_pass http://127.0.0.1:3080;
  proxy_http_version 1.1;
  proxy_set_header Host 127.0.0.1:3080;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_read_timeout 3600s;
}

location ~ ^(?:/[a-zA-Z]:)?/plugin/u?(?:2469233489|[0-9]+)/dsh/(?:index\.html/)?(.*)$ {
  rewrite ^(?:/[a-zA-Z]:)?/plugin/u?(?:2469233489|[0-9]+)/dsh/(?:index\.html/)?(.*)$ /$1 break;
  proxy_pass http://127.0.0.1:3080;
  proxy_http_version 1.1;
  proxy_set_header Host 127.0.0.1:3080;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_read_timeout 3600s;
}
```

---

## 4. 固件重启自愈与防清空防护 (Shield)

### 1) 云端同步防冲刷守护 (`plugincenter-shield.service`)
- **背景问题**：小米官方 `minas.plugin_center.service` 会定时从米家云端同步白名单应用。若发现本地安装了未在云端报备的自制插件，会直接覆盖并重置 `.list`，导致自制插件图标在米家 App 中消失。
- **防护机制**：通过在 `/data/plugincenter_shield/` 部署防护拦截脚本并注册为开机前置服务：
  - 在 `minas.plugin_center.service` 启动前恢复自制插件配置。
  - 对 `/data/plugin/*.list` 变更做监听和合并保护。

### 2) 开机恢复单元 (`<plugin>-restore.service`)
- 每个关键插件均在 `/data/backup/plugins/<plugin>/restore.sh` 备份恢复脚本。
- 由 `/etc/systemd/system/<plugin>-restore.service`（`Type=oneshot`，`RemainAfterExit=yes`）在系统开机、网络就绪后自动执行，恢复：
  - `.list` 注册信息
  - 图标与软链
  - Nginx location 规则并执行 `nginx -s reload`
  - 特殊防火墙/iptables 路由规则
