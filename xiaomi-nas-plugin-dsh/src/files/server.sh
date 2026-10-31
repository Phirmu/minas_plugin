#!/bin/sh
PLUGIN="dsh"
PORT="${PLUG_PORT:-3080}"
LOGDIR="/tmp/${PLUGIN}"
PIDFILE="${LOGDIR}/server.pid"
NODE_BIN="/data/phirmu/.nvm/versions/node/v26.13.0/bin/node"
DSH_BIN="/data/phirmu/.npm/_npx/1e7f6d9597241db0/node_modules/.bin/dsh"

patch_frontend() {
    python3 - <<'EOF' 2>/dev/null || true
import glob
pattern = "/data/phirmu/.npm/_npx/*/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/index-*.js"
for fpath in glob.glob(pattern):
    try:
        with open(fpath, "r", encoding="utf-8") as f:
            code = f.read()
        ch = False
        o1 = 'function u7(e){return!(!e.prototype||e instanceof Tb||_h!==Function&&e instanceof _h)}'
        n1 = 'function u7(e){return typeof e=="function"&&(/^class\\s/.test(Function.prototype.toString.call(e))||!(!e.prototype||e instanceof Tb||_h!==Function&&e instanceof _h))}'
        if o1 in code:
            code = code.replace(o1, n1); ch = True
        o2 = 'execute:function(){if(u7(i.callback)){const u=new i.callback(this.ctx,this.config);for(const h of u?.[ce.initHooks]??[])h();return u?.[ce.init]?.()}else return i.callback(this.ctx,this.config)}'
        n2 = 'execute:function(){let isCls=false;try{isCls=typeof i.callback==="function"&&/^class\\s/.test(Function.prototype.toString.call(i.callback));}catch(e){}if(u7(i.callback)||isCls){const u=new i.callback(this.ctx,this.config);for(const h of u?.[ce.initHooks]??[])h();return u?.[ce.init]?.()}else return i.callback(this.ctx,this.config)}'
        if o2 in code:
            code = code.replace(o2, n2); ch = True
        if ch:
            with open(fpath, "w", encoding="utf-8") as f:
                f.write(code)
    except Exception:
        pass
EOF
}

start() {
    mkdir -p "$LOGDIR"
    patch_frontend
    if curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || [ $? -eq 22 ]; then
        echo "dsh is already responding on port ${PORT}"
        return 0
    fi
    if [ -f "/etc/systemd/system/${PLUGIN}.service" ]; then
        systemctl start "${PLUGIN}.service"
        return $?
    fi
    su - phirmu -c "export PATH=/data/phirmu/.nvm/versions/node/v26.13.0/bin:\$PATH; cd /data/phirmu; nohup $NODE_BIN $DSH_BIN web --no-open --port $PORT --host 127.0.0.1 >>${LOGDIR}/server.log 2>&1 &"
    echo "Started ${PLUGIN} on port ${PORT}"
}

stop() {
    if [ -f "/etc/systemd/system/${PLUGIN}.service" ]; then
        systemctl stop "${PLUGIN}.service" 2>/dev/null || true
    fi
    pkill -u phirmu -f "dsh web" 2>/dev/null || true
}

status() {
    if curl -s --max-time 1 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
        echo "running"
        return 0
    fi
    # HTTP 401 also means dsh is running and listening!
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 1 "http://127.0.0.1:${PORT}/" 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "401" ] || [ "$CODE" = "302" ] || [ "$CODE" = "303" ]; then
        echo "running"
        return 0
    fi
    if pgrep -f "dsh web" >/dev/null 2>&1; then
        echo "running"
        return 0
    fi
    echo "stopped"
    return 1
}

restart() {
    stop
    sleep 1
    start
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    status)  status ;;
    *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
