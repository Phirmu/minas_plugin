#!/bin/sh
# ttyd 部署脚本 — 在小米 NAS 上以 root 执行
# 用法: sh deploy.sh <uid> [nas_ip]
set -e

UID_NUM="${1:-}"
case "$UID_NUM" in
    ''|*[!0-9]*) echo "Usage: sh deploy.sh <NAS_UID> [NAS_IP]" >&2; exit 2 ;;
esac
NAS_IP="${2:-127.0.0.1}"
PLUGIN="ttyd"
USER_NAME="u${UID_NUM}"
SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="/home/${USER_NAME}/plugin/${PLUGIN}"
WWW_DIR="/data/plugin/www/${USER_NAME}"
ICON_DST="/data/plugin/www/icon/${PLUGIN}.icon"
LIST_FILE="/data/plugin/${USER_NAME}.list"
NGINX_CONF="/etc/nginx/conf.d/luci/plugincenter.conf"
BACKUP_DIR="/data/backup/plugins/${PLUGIN}"
RESTORE_UNIT="/etc/systemd/system/${PLUGIN}-restore.service"
STAMP="$(date +%F-%H%M%S)"
PORT="7681"

echo "==> [1/8] 备份 .list / nginx 配置"
[ -f "$LIST_FILE" ] && cp "$LIST_FILE" "${LIST_FILE}.bak-${STAMP}" && echo "    → ${LIST_FILE}.bak-${STAMP}"
[ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak-${STAMP}" && echo "    → ${NGINX_CONF}.bak-${STAMP}"

echo "==> [2/8] 部署插件目录（真机布局 src/{files,ui}）"
mkdir -p "${HOME_DIR}/src" "${HOME_DIR}/scripts"
cp -a "${SRC_ROOT}/INFO" "${HOME_DIR}/INFO"
rm -rf "${HOME_DIR}/src/files" "${HOME_DIR}/src/ui"
cp -a "${SRC_ROOT}/src/files" "${SRC_ROOT}/src/ui" "${HOME_DIR}/src/"
chmod +x "${HOME_DIR}/src/files/ttyd" 2>/dev/null || true
chmod +x "${HOME_DIR}/src/files/server.sh" "${HOME_DIR}/src/ui/${PLUGIN}.cgi"
cp -a "${SRC_ROOT}/scripts/control" "${HOME_DIR}/scripts/control"
chmod +x "${HOME_DIR}/scripts/control"
chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}" 2>/dev/null || true
# ttyd binary owned by root so it can spawn root shell
chmod 755 "${HOME_DIR}/src/files/ttyd"

echo "==> [3/8] www 软链 + 图标"
mkdir -p "$WWW_DIR" "/data/plugin/www/icon"
ln -sfn "${HOME_DIR}/src/ui" "${WWW_DIR}/${PLUGIN}"
cp "${HOME_DIR}/src/ui/icon.png" "$ICON_DST"
chown "${USER_NAME}:${USER_NAME}" "$ICON_DST" 2>/dev/null || true

echo "==> [4/8] 注册 .list 条目"
python3 - "$LIST_FILE" "$PLUGIN" "$UID_NUM" "$PORT" "${BACKUP_DIR}" "${SRC_ROOT}/deploy/list-entry.json" <<'PY'
import json, time, sys, os
path, plugin, uid, port, backup_dir, tmpl_path = sys.argv[1:7]
home = f"/home/u{uid}/plugin/{plugin}"

entry = json.load(open(tmpl_path))
# Update UID in mpk and changetime
entry[plugin]["resource"]["mpk"] = f"{home}/INFO"
entry[plugin]["changetime"] = int(time.time())
entry[plugin]["info"]["timestamp"] = int(time.time())

data = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"WARN: 读取 {path} 失败: {e}，将新建")

data[plugin] = entry[plugin]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)

os.makedirs(backup_dir, exist_ok=True)
with open(os.path.join(backup_dir, "list-entry.json"), "w", encoding="utf-8") as f:
    json.dump({plugin: entry[plugin]}, f, ensure_ascii=False, indent=1)

print(f"    已在 {path} 写入 {plugin} 条目")
PY

echo "==> [5/8] 配置 Nginx 反代规则（支持 WebSocket）"
python3 - "$NGINX_CONF" "$UID_NUM" "$PORT" <<'PY'
import sys, os, re
path, uid, port = sys.argv[1], sys.argv[2], sys.argv[3]
block = f"""# === ttyd (auto-added) ===
location ~ ^(?:/[a-zA-Z]:)?/plugin/u?(?:{uid}|[0-9]+)/ttyd/(?:index\\.html)?$ {{
  if ($http_authorization != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$http_authorization; Path=/; HttpOnly; Secure" always;
  }}
  if ($arg_token != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$arg_token; Path=/; HttpOnly; Secure" always;
  }}
  rewrite ^ / break;
  proxy_pass http://127.0.0.1:{port};
  proxy_http_version 1.1;
  proxy_set_header Host 127.0.0.1:{port};
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_read_timeout 3600s;
}}

location ~ ^(?:/[a-zA-Z]:)?/plugin/u?(?:{uid}|[0-9]+)/ttyd/(?:index\\.html/)?(.*)$ {{
  if ($http_authorization != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$http_authorization; Path=/; HttpOnly; Secure" always;
  }}
  if ($arg_token != "") {{
    add_header 'Access-Control-Allow-Credentials' "true" always;
    add_header Set-Cookie "token=$arg_token; Path=/; HttpOnly; Secure" always;
  }}
  rewrite ^(?:/[a-zA-Z]:)?/plugin/u?(?:{uid}|[0-9]+)/ttyd/(?:index\\.html/)?(.*)$ /$1 break;
  proxy_pass http://127.0.0.1:{port};
  proxy_http_version 1.1;
  proxy_set_header Host 127.0.0.1:{port};
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_read_timeout 3600s;
}}
# === /ttyd ===
"""
with open(path) as f:
    content = f.read()

# 清理旧的 ttyd 块
content = re.sub(r'# === ttyd \(auto-added\) ===.*?# === /ttyd ===\n?', '', content, flags=re.DOTALL)

lines = content.splitlines(keepends=True)
out = []
inserted = False
for line in lines:
    if not inserted and "location /plugin" in line:
        out.append(block)
        inserted = True
    out.append(line)
if not inserted:
    out.append(block)

with open(path, "w") as f:
    f.writelines(out)
print(f"    已向 {path} 注入 ttyd location 规则")

luci_path = '/etc/nginx/sites-available/luci.conf'
if os.path.exists(luci_path):
    with open(luci_path, 'r', encoding='utf-8') as lf:
        lc = lf.read()
    old_m = 'map "$ssl_client_cert|$http_authorization|$arg_token|$http_cookie" $need_reject {\n\t"~^\\|\\|\\|$" 1;\n\tdefault 0;\n}'
    new_m = 'map "$uri|$ssl_client_cert|$http_authorization|$arg_token|$http_cookie" $need_reject {\n\t"~^/(?:[a-zA-Z]:/)?plugin/.*" 0;\n\t"~^[^|]*\\|\\|\\|\\|$" 1;\n\tdefault 0;\n}'
    if old_m in lc:
        lc = lc.replace(old_m, new_m)
        with open(luci_path, 'w', encoding='utf-8') as lf:
            lf.write(lc)
        print("    已更新 luci.conf 放行插件路径")
PY

nginx -t && nginx -s reload && echo "    nginx reload 成功"

echo "==> [6/8] 启动服务（通过 scripts/control postinstall）"
PLUG_SRC_DIR="${HOME_DIR}/src" \
PLUG_HOME_DIR="${HOME_DIR}" \
PLUG_USER="${USER_NAME}" \
PLUG_PORT_ALLOC="${PORT}" \
sh "${HOME_DIR}/scripts/control" postinstall

echo "==> [7/8] 配置重启自愈服务"
mkdir -p "${BACKUP_DIR}"
rm -rf "${BACKUP_DIR}/${PLUGIN}"
cp -a "${HOME_DIR}" "${BACKUP_DIR}/${PLUGIN}"

cat > "${BACKUP_DIR}/restore.sh" <<'RST'
#!/bin/sh
UID_N=__NAS_UID__
PLUGIN=ttyd
PORT=7681
USER_NAME=u${UID_N}
HOME_DIR=/home/${USER_NAME}/plugin/${PLUGIN}
WWW_DIR=/data/plugin/www/${USER_NAME}
LIST_FILE=/data/plugin/${USER_NAME}.list
NGINX_CONF=/etc/nginx/conf.d/luci/plugincenter.conf
BACKUP_DIR=/data/backup/plugins/${PLUGIN}
SRC=${BACKUP_DIR}/${PLUGIN}

if [ ! -f "${HOME_DIR}/INFO" ] && [ -f "${SRC}/INFO" ]; then
    mkdir -p /home/${USER_NAME}/plugin
    cp -a "${SRC}" "${HOME_DIR}"
    chmod +x "${HOME_DIR}/scripts/control" "${HOME_DIR}/src/files/server.sh" "${HOME_DIR}/src/ui/${PLUGIN}.cgi" "${HOME_DIR}/src/files/ttyd" 2>/dev/null || true
    echo "restore: 插件目录已恢复"
fi

mkdir -p "${WWW_DIR}" /data/plugin/www/icon
ln -sfn "${HOME_DIR}/src/ui" "${WWW_DIR}/${PLUGIN}"
cp "${HOME_DIR}/src/ui/icon.png" "/data/plugin/www/icon/${PLUGIN}.icon" 2>/dev/null || true

if [ -f "${BACKUP_DIR}/list-entry.json" ]; then
    python3 - "${LIST_FILE}" "${BACKUP_DIR}/list-entry.json" <<'PY2'
import json, sys, os
list_path, entry_path = sys.argv[1], sys.argv[2]
entry = json.load(open(entry_path))
data = {}
if os.path.isfile(list_path):
    with open(list_path) as f:
        data = json.load(f)
data.update(entry)
with open(list_path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
PY2
fi

if [ -f "${HOME_DIR}/scripts/control" ]; then
    PLUG_SRC_DIR="${HOME_DIR}/src" PLUG_HOME_DIR="${HOME_DIR}" PLUG_USER="${USER_NAME}" \
      PLUG_PORT_ALLOC="${PORT}" sh "${HOME_DIR}/scripts/control" postinstall
fi

if [ -f "$NGINX_CONF" ] && ! grep -q "ttyd" "$NGINX_CONF"; then
    sh "${SRC}/deploy/deploy.sh" "$UID_N"
fi
exit 0
RST
sed -i "s/^UID_N=__NAS_UID__$/UID_N=${UID_NUM}/" "${BACKUP_DIR}/restore.sh"
chmod +x "${BACKUP_DIR}/restore.sh"

cat > "$RESTORE_UNIT" <<UNIT
[Unit]
Description=${PLUGIN} plugin restore on boot
After=network.target
Before=${PLUGIN}.service
ConditionPathExists=${BACKUP_DIR}/restore.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${BACKUP_DIR}/restore.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "${PLUGIN}-restore.service"

echo "==> [8/8] 验收"
sleep 1
if curl -fsS --max-time 3 http://127.0.0.1:7681/ >/dev/null; then
    echo "    ✓ ttyd 服务运行正常 (http://127.0.0.1:7681/)"
else
    echo "    WARN: ttyd 端口未响应，请查看 /tmp/ttyd/server.log"
fi
echo "✓ ttyd 部署完成"
