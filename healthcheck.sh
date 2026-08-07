#!/bin/sh
set -eu

DROPBEAR_RUN_DIR=/run/dropbear
ROOT_HOME=/run/root
HOST_KEY="$DROPBEAR_RUN_DIR/dropbear_ed25519_host_key"
DROPBEAR_PIDFILE="$DROPBEAR_RUN_DIR/dropbear.pid"
AUTHORIZED_KEYS_FILE="$ROOT_HOME/.ssh/authorized_keys"

has_authorized_key() {
    [ -f "$AUTHORIZED_KEYS_FILE" ] || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*)
                continue
                ;;
            ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *)
                return 0
                ;;
        esac
    done < "$AUTHORIZED_KEYS_FILE"
    return 1
}

require_running_pidfile() {
    pidfile="$1"
    name="$2"

    [ -s "$pidfile" ] || {
        echo "$name pidfile missing"
        exit 1
    }

    pid="$(cat "$pidfile")"
    case "$pid" in
        ''|*[!0-9]*)
            echo "$name pidfile is invalid: $pid"
            exit 1
            ;;
    esac

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "$name pid $pid is not running"
        exit 1
    fi
}

[ -s "$HOST_KEY" ] || {
    echo "dropbear host key missing"
    exit 1
}

require_running_pidfile "$DROPBEAR_PIDFILE" "dropbear"

if ! has_authorized_key; then
    echo "authorized_keys missing or empty"
    exit 1
fi

exit 0
