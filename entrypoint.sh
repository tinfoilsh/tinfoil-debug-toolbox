#!/bin/sh
set -eu

# Tinfoil Debug SSH Toolbox
# Dropbear, /bin/sh, Docker CLI, and helper commands live in this measured
# container. The stripped CVM host provides only the Docker socket.

log() {
    msg="tinfoil-debug-toolbox: $*"
    printf '%s\n' "$msg"
    if [ -e /dev/console ]; then
        (printf '%s\n' "$msg" > /dev/console) 2>/dev/null || true
    fi
}

die() {
    printf '%s\n' "tinfoil-debug-toolbox: ERROR - $*" >&2
    exit 1
}

cleanup() {
    rm -f /run/dropbear/*.pem /run/dropbear/*.tmp 2>/dev/null || true
}
trap cleanup EXIT

# --- Validate inputs -----------------------------------------------------------

[ -n "${SSH_AUTHORIZED_KEYS:-}" ] || die "SSH_AUTHORIZED_KEYS not set (pass via secrets in external config)"

# Sanity-check: every non-empty line must look like an SSH public key.
# Uses here-doc (not pipe) so die() exits the main shell, not a subshell.
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
        \#*) ;;  # allow comments
        *) die "SSH_AUTHORIZED_KEYS contains invalid line: ${line%% *}..." ;;
    esac
done <<EOF
$SSH_AUTHORIZED_KEYS
EOF

# --- Layout -------------------------------------------------------------------
#   /run/dropbear/      - host key and pidfile tmpfs
#   /root/.ssh/         - authorized_keys tmpfs
#   /usr/local/bin/     - static Dropbear, Docker CLI, and toolbox helpers

log "setting up toolbox state"
mkdir -p /run/dropbear /root/.ssh /tmp
chmod 700 /run/dropbear /root/.ssh

# Host key setup
#    Accepts OpenSSH PEM format (native output of ssh-keygen / Go crypto/ssh).
#    Converted to Dropbear format at install time via dropbearconvert.
#    If not provided, generates an ephemeral key (changes every boot).
HOST_KEY=/run/dropbear/dropbear_ed25519_host_key
if [ -n "${SSH_HOST_KEY:-}" ]; then
    case "$SSH_HOST_KEY" in
        "-----BEGIN OPENSSH PRIVATE KEY-----"*)
            log "converting OpenSSH host key to Dropbear format"
            printf '%s\n' "$SSH_HOST_KEY" > /run/dropbear/hostkey.pem
            chmod 600 /run/dropbear/hostkey.pem
            /usr/local/bin/dropbearconvert openssh dropbear /run/dropbear/hostkey.pem "$HOST_KEY" \
                || die "dropbearconvert failed - is SSH_HOST_KEY a valid OpenSSH ed25519 private key?"
            ;;
        *)
            die "SSH_HOST_KEY must be an OpenSSH PEM private key (-----BEGIN OPENSSH PRIVATE KEY-----). Generate with: ssh-keygen -t ed25519 -f host_key -N ''"
            ;;
    esac
    chmod 600 "$HOST_KEY"
else
    log "generating ephemeral host key (set SSH_HOST_KEY secret for stable identity)"
    /usr/local/bin/dropbearkey -t ed25519 -f "$HOST_KEY"
fi

# Write authorized keys.
log "writing authorized keys"
printf '%s\n' "$SSH_AUTHORIZED_KEYS" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

# Start Dropbear in the foreground. The container is the supervisor.
SSH_PORT="${SSH_PORT:-22}"
case "$SSH_PORT" in
    ''|*[!0-9]*)
        die "SSH_PORT must be numeric"
        ;;
esac
log "starting dropbear toolbox on port $SSH_PORT"
exec /usr/local/bin/dropbear -F -E \
    -p "$SSH_PORT" \
    -P /run/dropbear/dropbear.pid \
    -r "$HOST_KEY" \
    -b /etc/motd \
    -s -g -j -k
