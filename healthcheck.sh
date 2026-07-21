#!/bin/sh
set -eu

pidfile=/run/dropbear/dropbear.pid

[ -s /root/.ssh/authorized_keys ] || {
    echo "authorized_keys missing"
    exit 1
}

[ -s /run/dropbear/dropbear_ed25519_host_key ] || {
    echo "dropbear host key missing"
    exit 1
}

[ -s "$pidfile" ] || {
    echo "dropbear pidfile missing"
    exit 1
}

pid="$(cat "$pidfile")"
case "$pid" in
    ''|*[!0-9]*)
        echo "dropbear pidfile is invalid: $pid"
        exit 1
        ;;
esac

if ! kill -0 "$pid" 2>/dev/null; then
    echo "dropbear pid $pid is not running"
    exit 1
fi

exit 0
