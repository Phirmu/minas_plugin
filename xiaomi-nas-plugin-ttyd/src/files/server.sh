#!/bin/sh
PLUGIN="ttyd"
PORT="${PLUG_PORT:-7681}"
LOGDIR="/tmp/${PLUGIN}"
PIDFILE="${LOGDIR}/server.pid"
TTYD_BIN="$(dirname "$0")/ttyd"

[ -x "$TTYD_BIN" ] || TTYD_BIN="/data/backup/plugins/${PLUGIN}/src/files/ttyd"
[ -x "$TTYD_BIN" ] || TTYD_BIN="/data/phirmu/.local/bin/ttyd"

start() {
    mkdir -p "$LOGDIR"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Already running (PID $(cat "$PIDFILE"))"
        return 0
    fi
    export TERM=xterm-256color
    export HOME=/root
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    nohup "$TTYD_BIN" -p "$PORT" -i 127.0.0.1 -W /bin/bash >>"${LOGDIR}/server.log" 2>&1 &
    echo $! > "$PIDFILE"
    echo "Started ${PLUGIN} on port ${PORT} (PID $!)"
}

stop() {
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE")"
        kill "$PID" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "Stopped PID $PID"
    fi
    pkill -f "ttyd -p $PORT" 2>/dev/null || true
}

status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "running"
        return 0
    fi
    if pgrep -f "ttyd -p $PORT" >/dev/null 2>&1; then
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
