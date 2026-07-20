#!/bin/sh
set -eu

# Tinfoil Debug SSH Toolbox
# Runs as a privileged debug-only container. Dropbear and the shell live in this
# container, while the CVM host root is mounted at /host for deliberate debug
# inspection. Nothing requires host systemd or a host /bin/sh.

write_serial() {
    for dev in /host/dev/hvc0 /host/dev/console; do
        [ -e "$dev" ] || continue
        (printf '%s\n' "$1" > "$dev") 2>/dev/null || true
    done
}

log() {
    msg="tinfoil-ssh-toolbox: $1"
    echo "$msg"
    write_serial "$msg"
}

die() {
    msg="tinfoil-ssh-toolbox: ERROR - $1"
    echo "$msg" >&2
    write_serial "$msg"
    exit 1
}

# Clean up temp files on any exit (success or failure)
cleanup() { rm -f "${BASE:-/nonexistent}/etc/"*.pem "${BASE:-/nonexistent}/etc/"*.tmp 2>/dev/null || true; }
trap cleanup EXIT

# --- Validate inputs -----------------------------------------------------------

[ -n "${SSH_AUTHORIZED_KEYS:-}" ] || die "SSH_AUTHORIZED_KEYS not set (pass via secrets in external config)"

# Sanity-check: every non-empty line must look like an SSH public key.
# Uses here-doc (not pipe) so die() exits the main shell, not a subshell.
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*|sk-ssh-*|ssh-dss\ *) ;;
        \#*) ;;  # allow comments
        *) die "SSH_AUTHORIZED_KEYS contains invalid line: ${line%% *}..." ;;
    esac
done <<EOF
$SSH_AUTHORIZED_KEYS
EOF

# --- Layout -------------------------------------------------------------------
#   /mnt/ramdisk/dropbear/bin/       - static binaries and toolbox wrappers
#   /mnt/ramdisk/dropbear/etc/       - host key
#   /root/.ssh/                      - authorized_keys tmpfs

BASE=/mnt/ramdisk/dropbear

# 1. Directory structure
log "setting up toolbox tmpfs"
mkdir -p "$BASE/bin" "$BASE/etc" /root/.ssh

# 2. Copy static binaries (no shared libraries needed)
log "copying static binaries to toolbox tmpfs"
cp /usr/local/bin/dropbear \
   /usr/local/bin/dropbearkey \
   /usr/local/bin/dropbearconvert \
   /usr/local/bin/scp \
   /usr/local/bin/sftp-server \
   "$BASE/bin/"
chmod 755 "$BASE/bin/"*

cat > "$BASE/bin/docker" <<'EOF'
#!/bin/sh
exec /usr/local/bin/docker -H unix:///host/run/docker.sock "$@"
EOF
chmod 755 "$BASE/bin/docker"

# 3. Host key setup
#    Accepts OpenSSH PEM format (native output of ssh-keygen / Go crypto/ssh).
#    Converted to Dropbear format at install time via dropbearconvert.
#    If not provided, generates an ephemeral key (changes every boot).
HOST_KEY="$BASE/etc/dropbear_ed25519_host_key"
if [ -n "${SSH_HOST_KEY:-}" ]; then
    case "$SSH_HOST_KEY" in
        "-----BEGIN OPENSSH PRIVATE KEY-----"*)
            log "converting OpenSSH host key to Dropbear format"
            printf '%s\n' "$SSH_HOST_KEY" > "$BASE/etc/hostkey.pem"
            chmod 600 "$BASE/etc/hostkey.pem"
            "$BASE/bin/dropbearconvert" openssh dropbear "$BASE/etc/hostkey.pem" "$HOST_KEY" \
                || die "dropbearconvert failed - is SSH_HOST_KEY a valid OpenSSH ed25519 private key?"
            ;;
        *)
            die "SSH_HOST_KEY must be an OpenSSH PEM private key (-----BEGIN OPENSSH PRIVATE KEY-----). Generate with: ssh-keygen -t ed25519 -f host_key -N ''"
            ;;
    esac
    chmod 600 "$HOST_KEY"
else
    log "generating ephemeral host key (set SSH_HOST_KEY secret for stable identity)"
    "$BASE/bin/dropbearkey" -t ed25519 -f "$HOST_KEY"
fi

# 4. Write authorized keys and bind mount over /root/.ssh
log "writing authorized keys"
printf '%s\n' "$SSH_AUTHORIZED_KEYS" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
cat > /root/.profile <<'EOF'
export DOCKER_HOST=unix:///host/run/docker.sock
export PATH=/mnt/ramdisk/dropbear/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /host/root 2>/dev/null || cd /
EOF
chmod 600 /root/.profile

# 5. Start Dropbear in the foreground. The container is the supervisor.
SSH_PORT="${SSH_PORT:-22}"
case "$SSH_PORT" in
    ''|*[!0-9]*)
        die "SSH_PORT must be numeric"
        ;;
esac
log "starting dropbear toolbox on port $SSH_PORT"
exec "$BASE/bin/dropbear" -F -E -p "$SSH_PORT" -P "$BASE/dropbear.pid" -r "$HOST_KEY" -s -g -j -k
