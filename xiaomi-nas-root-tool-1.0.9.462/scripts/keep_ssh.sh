#!/bin/sh
# Xiaomi NAS SSH Persistence & Unrestrict script
# Deployed at: /data/auto_ssh/keep_ssh.sh
# Triggered by: systemd auto-ssh.service, OTA syshotplug hooks, and crontab

PUBKEY_BACKUP="/data/auto_ssh/authorized_keys"

# 1. 确保 /etc/shells 中包含有效 bash 路径
grep -q "^/bin/bash$" /etc/shells 2>/dev/null || echo "/bin/bash" >> /etc/shells
grep -q "^/usr/bin/bash$" /etc/shells 2>/dev/null || echo "/usr/bin/bash" >> /etc/shells

# 2. 确保 root 的登录 shell 是 /usr/bin/bash (绕过 mi-shell 限制)
sed -i "s#^root:x:0:0:root:[^:]*:/usr/sbin/mi-shell#root:x:0:0:root:/home/rootx:/usr/bin/bash#" /etc/passwd 2>/dev/null
sed -i "s#^root:x:0:0:root:/root:#root:x:0:0:root:/home/rootx:#" /etc/passwd 2>/dev/null
sed -i "s#:/usr/sbin/mi-shell$#:/usr/bin/bash#" /etc/passwd 2>/dev/null

# 3. 动态 bind-mount 覆盖 /usr/sbin/mi-shell (应对 dropbear 源码硬编码执行 mi-shell)
if ! mountpoint -q /usr/sbin/mi-shell; then
    mount --bind /bin/bash /usr/sbin/mi-shell 2>/dev/null
fi

# 4. 确保 root 公钥注入 (恢复 /home/rootx 与 /etc/dropbear)
mkdir -p /home/rootx/.ssh /etc/dropbear
chmod 700 /home/rootx /home/rootx/.ssh /etc/dropbear

if [ -f "$PUBKEY_BACKUP" ]; then
    while read -r key; do
        [ -n "$key" ] || continue
        grep -q "$key" /home/rootx/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /home/rootx/.ssh/authorized_keys
        grep -q "$key" /etc/dropbear/authorized_keys 2>/dev/null || echo "$key" >> /etc/dropbear/authorized_keys
    done < "$PUBKEY_BACKUP"
    chmod 600 /home/rootx/.ssh/authorized_keys /etc/dropbear/authorized_keys
fi

# 5. 确保持久化 sudo 用户 phirmu 存在且配置完整 (Home 在 /data/phirmu)
if ! id phirmu >/dev/null 2>&1; then
    useradd -d /data/phirmu -s /bin/bash -u 10372 phirmu 2>/dev/null || useradd -d /data/phirmu -s /bin/bash phirmu 2>/dev/null
fi

if [ ! -f /etc/sudoers.d/phirmu ]; then
    mkdir -p /etc/sudoers.d
    echo "phirmu ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/phirmu
    chmod 440 /etc/sudoers.d/phirmu
fi

mkdir -p /data/phirmu/.ssh
chmod 700 /data/phirmu /data/phirmu/.ssh
if [ -f "$PUBKEY_BACKUP" ]; then
    while read -r key; do
        [ -n "$key" ] || continue
        grep -q "$key" /data/phirmu/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /data/phirmu/.ssh/authorized_keys
    done < "$PUBKEY_BACKUP"
    chmod 600 /data/phirmu/.ssh/authorized_keys
fi
chown -R phirmu:phirmu /data/phirmu

# 6. 确保 Dropbear 服务开机自启并当前正在运行
systemctl is-enabled dropbear.socket >/dev/null 2>&1 || systemctl enable dropbear.socket 2>/dev/null
systemctl is-active dropbear.socket >/dev/null 2>&1 || systemctl start dropbear.socket 2>/dev/null

exit 0
