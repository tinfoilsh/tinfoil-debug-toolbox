#!/bin/sh
set -eu
umask 077

DROPBEAR_RUN_DIR=/run/dropbear
ROOT_HOME=/run/root
HOST_KEY="$DROPBEAR_RUN_DIR/dropbear_ed25519_host_key"
HOST_KEY_PEM="$DROPBEAR_RUN_DIR/hostkey.pem"
DROPBEAR_PIDFILE="$DROPBEAR_RUN_DIR/dropbear.pid"
AUTHORIZED_KEYS_FILE="$ROOT_HOME/.ssh/authorized_keys"
TOOLBOX_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TOOLBOX_DOCS=/usr/share/tinfoil-debug-toolbox

dropbear_pid=
stopping=0
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
    rm -f "$HOST_KEY_PEM" "$DROPBEAR_PIDFILE" "$DROPBEAR_RUN_DIR"/*.tmp 2>/dev/null || true
}

stop_children() {
    [ -n "$dropbear_pid" ] && kill -TERM "$dropbear_pid" 2>/dev/null || true
}

trap cleanup EXIT
trap 'stopping=1; log "forwarding TERM to supervised children"; stop_children' TERM INT HUP QUIT

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

[ "$authorized_keys_present" -eq 1 ] || die "SSH_AUTHORIZED_KEYS must contain at least one valid SSH public key"

log "setting up toolbox state"
mkdir -p "$DROPBEAR_RUN_DIR" "$ROOT_HOME" /tmp
chmod 700 "$DROPBEAR_RUN_DIR" "$ROOT_HOME"
[ -f /etc/tinfoil-root-profile ] && [ ! -f "$ROOT_HOME/.profile" ] && cp /etc/tinfoil-root-profile "$ROOT_HOME/.profile" && chmod 600 "$ROOT_HOME/.profile"
for document in README.md AGENTS.md; do
    [ -f "$ROOT_HOME/$document" ] || cp "$TOOLBOX_DOCS/$document" "$ROOT_HOME/$document"
    chmod 600 "$ROOT_HOME/$document"
done
if [ -f /tinfoil/config.yml ] && [ ! -f "$ROOT_HOME/tinfoil-config.debug.yml" ]; then
    if ! /usr/local/bin/tindbg template >/dev/null; then
        log "warning: verified config template is not available yet"
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

mkdir -p "$ROOT_HOME/.ssh"
chmod 700 "$ROOT_HOME/.ssh"
printf '%s\n' "$SSH_AUTHORIZED_KEYS" > "$AUTHORIZED_KEYS_FILE"
chmod 600 "$AUTHORIZED_KEYS_FILE"

export HOME="$ROOT_HOME"
export DOCKER_HOST=unix:///var/run/docker.sock
export PATH="$TOOLBOX_PATH"
cd "$ROOT_HOME"

log "starting dropbear toolbox on port 2222"
/usr/local/bin/dropbear -F -E -p 2222 -P "$DROPBEAR_PIDFILE" -r "$HOST_KEY" -s -g -j -k &
dropbear_pid=$!

while :; do
    if [ -n "$dropbear_pid" ] && ! kill -0 "$dropbear_pid" 2>/dev/null; then
        if wait "$dropbear_pid"; then dropbear_status=0; else dropbear_status=$?; fi
        dropbear_pid=
        [ "$stopping" -eq 1 ] && break
        log "dropbear exited with status $dropbear_status"
        exit 1
    fi
    [ "$stopping" -eq 1 ] && [ -z "$dropbear_pid" ] && break
    sleep 1
done
