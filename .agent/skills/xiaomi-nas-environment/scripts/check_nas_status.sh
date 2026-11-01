#!/bin/sh
# Xiaomi NAS 健康状态与插件服务速查脚本
# 用法: 在 NAS 端以 root 或在本地通过 ssh 执行

echo "=========================================================="
echo "          Xiaomi NAS 运行环境与插件状态巡检"
echo "=========================================================="
echo "执行时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "内核版本: $(uname -r) ($(uname -m))"
echo "系统运行: $(uptime)"
echo

echo "--- [1] 存储分区容量 ---"
df -h | grep -E "Filesystem|/data$|/home$|/nas/pool0" || df -h /data /nas/pool0
echo

echo "--- [2] 关键用户组与成员 ---"
grep -E "naspub|nasadm|docker|phirmu" /etc/group
echo

echo "--- [3] 核心插件服务运行状态 ---"
for svc in dsh ttyd motrix-web-proxy docker plugincenter-shield; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        echo "  [✓] ${svc}.service: RUNNING"
    else
        echo "  [✗] ${svc}.service: STOPPED / FAILED"
    fi
done
echo

echo "--- [4] 插件本地端口监听 (3080, 7681, 8080, 9301, 9302, 9303) ---"
for port in 3080 7681 8080 9301 9302 9303; do
    if ss -tulpn | grep -q ":${port} "; then
        proc=$(ss -tulpn | grep ":${port} " | awk '{print $NF}' | head -n 1)
        echo "  [✓] 端口 :${port} 监听正常 (${proc})"
    else
        echo "  [✗] 端口 :${port} 未在监听"
    fi
done
echo

echo "--- [5] Nginx 配置文件测试 ---"
nginx -t 2>&1 | head -n 2
echo

echo "--- [6] 用户插件清单状态 (/data/plugin/*.list) ---"
ls -la /data/plugin/*.list 2>/dev/null
echo "=========================================================="
