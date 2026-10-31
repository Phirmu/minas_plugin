# 小米 NAS ttyd Web 终端插件

基于 [ttyd](https://github.com/tsl0922/ttyd) 为小米智能存储（Xiaomi NAS）提供的原生 Web 终端插件。

## 特性

- **原生 aarch64 静态二进制**：直接在 NAS 上轻量运行，无需庞大容器开销。
- **Web 终端全功能支持**：完整支持 ANSI 颜色、快捷键、复制粘贴及 trzsz / lrzsz 文件传输。
- **WebSocket 代理**：通过 Xiaomi NAS 的 Nginx 反向代理与 mTLS 安全通道无缝接入。
- **开机自愈机制**：具备 systemd 服务托管及固件重启后插件自愈恢复能力。

## 部署

通过仓库统一入口部署：

```bash
python deploy-plugins.py --select ttyd
```

或手动执行部署脚本：

```bash
sh deploy/deploy.sh <NAS_UID>
```
