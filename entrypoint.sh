#!/bin/sh
set -eu
umask 077

DROPBEAR_RUN_DIR=/run/dropbear
ROOT_HOME=/run/root
HOST_KEY="$DROPBEAR_RUN_DIR/dropbear_ed25519_host_key"
HOST_KEY_PEM="$DROPBEAR_RUN_DIR/hostkey.pem"
DROPBEAR_PIDFILE="$DROPBEAR_RUN_DIR/dropbear.pid"
CONSOLE_DEVICE=/dev/hvc1
CONSOLE_PIDFILE=/run/tinfoil-toolbox-console.pid
AUTHORIZED_KEYS_FILE="$ROOT_HOME/.ssh/authorized_keys"
TOOLBOX_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TOOLBOX_DOCS=/usr/share/tinfoil-debug-toolbox

dropbear_pid=
console_supervisor_pid=
stopping=0
console_available=0
authorized_keys_present=0

log() {
    msg="tinfoil-debug-toolbox: $*"
    printf '%s\n' "$msg"
    [ -e /dev/console ] && (printf '%s\n' "$msg" > /dev/console) 2>/dev/null || true
}

die() {
    printf '%s\n' "tinfoil-debug-toolbox: ERROR - $*" >&2
    exit 1
}

cleanup() {
    rm -f "$HOST_KEY_PEM" "$DROPBEAR_PIDFILE" "$CONSOLE_PIDFILE" "$DROPBEAR_RUN_DIR"/*.tmp 2>/dev/null || true
}

stop_children() {
    [ -n "$dropbear_pid" ] && kill -TERM "$dropbear_pid" 2>/dev/null || true
    [ -n "$console_supervisor_pid" ] && kill -TERM "$console_supervisor_pid" 2>/dev/null || true
}

console_supervisor() {
    console_shell_pid=
    console_stop=0
    immediate_failures=0
    trap 'console_stop=1; [ -n "${console_shell_pid:-}" ] && kill -TERM "$console_shell_pid" 2>/dev/null || true' TERM INT HUP QUIT
    while :; do
        started_at="$(date +%s)"
        log "starting BusyBox root toolbox console on $CONSOLE_DEVICE"
        /bin/setsid /bin/sh -c \
            'exec /bin/cttyhack /usr/local/bin/toolbox-shell </dev/hvc1 >/dev/hvc1 2>&1' &
        console_shell_pid=$!
        if wait "$console_shell_pid"; then console_status=0; else console_status=$?; fi
        console_shell_pid=
        [ "$console_stop" -eq 1 ] && exit 0

        runtime=$(($(date +%s) - started_at))
        if [ "$runtime" -lt 2 ]; then
            immediate_failures=$((immediate_failures + 1))
            log "toolbox console shell exited after ${runtime}s with status $console_status ($immediate_failures/3 immediate failures)"
            [ "$immediate_failures" -lt 3 ] || die "toolbox console shell repeatedly failed immediately"
            sleep 1
        else
            immediate_failures=0
            log "toolbox console shell exited with status $console_status; restarting"
        fi
    done
}

trap cleanup EXIT
trap 'stopping=1; log "forwarding TERM to supervised children"; stop_children' TERM INT HUP QUIT

if [ -e "$CONSOLE_DEVICE" ]; then
    [ -c "$CONSOLE_DEVICE" ] || die "$CONSOLE_DEVICE exists but is not a character device"
    /bin/stty -F "$CONSOLE_DEVICE" >/dev/null 2>&1 || die "$CONSOLE_DEVICE is not a usable terminal"
    console_available=1
fi

while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        \#*)
            continue
            ;;
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *)
            authorized_keys_present=1
            ;;
        *)
            die "SSH_AUTHORIZED_KEYS contains invalid line: ${line%% *}..."
            ;;
    esac
done <<EOF
${SSH_AUTHORIZED_KEYS:-}
EOF

[ "$authorized_keys_present" -eq 1 ] || [ "$console_available" -eq 1 ] || die "SSH_AUTHORIZED_KEYS is empty and /dev/hvc1 toolbox console is unavailable"

log "setting up toolbox state"
mkdir -p "$DROPBEAR_RUN_DIR" "$ROOT_HOME" /tmp
chmod 700 "$DROPBEAR_RUN_DIR" "$ROOT_HOME"
[ -f /etc/tinfoil-root-profile ] && [ ! -f "$ROOT_HOME/.profile" ] && cp /etc/tinfoil-root-profile "$ROOT_HOME/.profile" && chmod 600 "$ROOT_HOME/.profile"
for document in README.md AGENTS.md; do
    [ -f "$ROOT_HOME/$document" ] || cp "$TOOLBOX_DOCS/$document" "$ROOT_HOME/$document"
    chmod 600 "$ROOT_HOME/$document"
done
if [ -S /run/tinfoil/containers.sock ] && [ ! -f "$ROOT_HOME/tinfoil-config.debug.yml" ]; then
    if ! /usr/local/bin/tindbg template >/dev/null; then
        log "warning: manager config template is not available yet"
    fi
fi

if [ -n "${SSH_HOST_KEY:-}" ]; then
    case "$SSH_HOST_KEY" in
        "-----BEGIN OPENSSH PRIVATE KEY-----"*)
            log "converting OpenSSH host key to Dropbear format"
            printf '%s\n' "$SSH_HOST_KEY" > "$HOST_KEY_PEM"
            chmod 600 "$HOST_KEY_PEM"
            /usr/local/bin/dropbearconvert openssh dropbear "$HOST_KEY_PEM" "$HOST_KEY" || {
                rm -f "$HOST_KEY_PEM"
                die "dropbearconvert failed - is SSH_HOST_KEY a valid OpenSSH ed25519 private key?"
            }
            rm -f "$HOST_KEY_PEM"
            chmod 600 "$HOST_KEY"
            ;;
        *)
            die "SSH_HOST_KEY must be an OpenSSH PEM private key (-----BEGIN OPENSSH PRIVATE KEY-----). Generate with: ssh-keygen -t ed25519 -f host_key -N ''"
            ;;
    esac
else
    log "generating ephemeral host key (set SSH_HOST_KEY secret for stable identity)"
    /usr/local/bin/dropbearkey -t ed25519 -f "$HOST_KEY"
fi

if [ "$authorized_keys_present" -eq 1 ]; then
    mkdir -p "$ROOT_HOME/.ssh"
    chmod 700 "$ROOT_HOME/.ssh"
    printf '%s\n' "$SSH_AUTHORIZED_KEYS" > "$AUTHORIZED_KEYS_FILE"
    chmod 600 "$AUTHORIZED_KEYS_FILE"
else
    rm -f "$AUTHORIZED_KEYS_FILE" 2>/dev/null || true
    log "toolbox console is enabled; SSH public keys are optional for this boot"
fi

export HOME="$ROOT_HOME"
export DOCKER_HOST=unix:///var/run/docker.sock
export PATH="$TOOLBOX_PATH"
cd "$ROOT_HOME"

if [ "$console_available" -eq 1 ]; then
    console_supervisor &
    console_supervisor_pid=$!
    printf '%s\n' "$console_supervisor_pid" > "$CONSOLE_PIDFILE"
fi

log "starting dropbear toolbox on port 2222"
/usr/local/bin/dropbear -F -E -p 2222 -P "$DROPBEAR_PIDFILE" -r "$HOST_KEY" -s -g -j -k &
dropbear_pid=$!

while :; do
    if [ -n "$dropbear_pid" ] && ! kill -0 "$dropbear_pid" 2>/dev/null; then
        if wait "$dropbear_pid"; then dropbear_status=0; else dropbear_status=$?; fi
        dropbear_pid=
        [ "$stopping" -eq 1 ] && break
        log "dropbear exited with status $dropbear_status"
        stop_children
        [ -n "$console_supervisor_pid" ] && wait "$console_supervisor_pid" 2>/dev/null || true
        exit 1
    fi
    if [ -n "$console_supervisor_pid" ] && ! kill -0 "$console_supervisor_pid" 2>/dev/null; then
        if wait "$console_supervisor_pid"; then console_status=0; else console_status=$?; fi
        console_supervisor_pid=
        [ "$stopping" -eq 1 ] && break
        log "toolbox console supervisor exited with status $console_status"
        stop_children
        [ -n "$dropbear_pid" ] && wait "$dropbear_pid" 2>/dev/null || true
        exit 1
    fi
    [ "$stopping" -eq 1 ] && [ -z "$dropbear_pid" ] && [ -z "$console_supervisor_pid" ] && break
    sleep 1
done
