#!/bin/sh
set -eu

DROPBEAR_RUN_DIR=/run/dropbear
ROOT_HOME=/run/root
HOST_KEY="$DROPBEAR_RUN_DIR/dropbear_ed25519_host_key"
DROPBEAR_PIDFILE="$DROPBEAR_RUN_DIR/dropbear.pid"
CONSOLE_DEVICE=/dev/hvc1
CONSOLE_PIDFILE=/run/tinfoil-toolbox-console.pid
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

console_available=0
if [ -e "$CONSOLE_DEVICE" ]; then
    [ -c "$CONSOLE_DEVICE" ] || {
        echo "$CONSOLE_DEVICE is not a character device"
        exit 1
    }
    /bin/stty -F "$CONSOLE_DEVICE" >/dev/null 2>&1 || {
        echo "$CONSOLE_DEVICE is not a usable terminal"
        exit 1
    }
    console_available=1
    require_running_pidfile "$CONSOLE_PIDFILE" "toolbox console"
fi

if ! has_authorized_key && [ "$console_available" -eq 0 ]; then
    echo "authorized_keys missing and toolbox console unavailable"
    exit 1
fi

exit 0
