#!/bin/sh
# dsh.cgi - CGI fallback for dsh plugin under Xiaomi NAS plugincenter
URI="${FILE_URI:-}"
REQ="${FILE_REQ:-}"

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
    echo -e "Status: 302 Found\r\nLocation: ./\r\n\r\n"
fi
