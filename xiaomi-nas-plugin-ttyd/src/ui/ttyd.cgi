#!/bin/sh
# ttyd.cgi - CGI fallback for ttyd plugin under Xiaomi NAS plugincenter
URI="${FILE_URI:-}"
REQ="${FILE_REQ:-}"

if [ -z "$URI" ] || [ "$URI" = "index.html" ] || [ "$URI" = "/" ]; then
    resp=$(curl -s --max-time 5 "http://127.0.0.1:7681/")
    if [ -n "$resp" ]; then
        echo -e "Content-type: text/html; charset=utf-8\r\nCache-Control: no-cache\r\n"
        echo "$resp"
        exit 0
    fi
fi

if [ -f "$REQ" ]; then
    ext="${REQ##*.}"
    case "$ext" in
        png)  mime="image/png" ;;
        css)  mime="text/css" ;;
        js)   mime="application/javascript" ;;
        html) mime="text/html" ;;
        svg)  mime="image/svg+xml" ;;
        json) mime="application/json" ;;
        *)    mime="application/octet-stream" ;;
    esac
    echo -e "Content-type: $mime\r\n"
    cat "$REQ"
else
    echo -e "Status: 404 Not Found\r\nContent-type: text/html\r\n\r\n"
    echo "<h1>404 Not Found</h1>"
fi
