#!/usr/bin/env bash
set -Eeuo pipefail
unset SSH_AUTH_SOCK

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tinfoil-debug-toolbox-contract.XXXXXXXX")"
tag="tinfoil-debug-toolbox-contract:$(date +%s)"
authorized_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey contract'
containers=()

cleanup() {
    if [ "${#containers[@]}" -gt 0 ]; then
        docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
    fi
    docker image rm -f "$tag" >/dev/null 2>&1 || true
    rm -rf -- "$scratch"
}
trap cleanup EXIT

wait_for_file() {
    local path="$1"
    for _ in $(seq 1 50); do
        if [ -e "$path" ]; then
            return 0
        fi
        sleep 0.2
    done
    echo "timed out waiting for $path" >&2
    return 1
}

start_container() {
    CID="$(docker run -d "$@")"
    containers+=("$CID")
}

mkdir -p "$scratch/stubs"

cat > "$scratch/stubs/dropbear-live" <<'EOF'
#!/bin/sh
set -eu
: > /state/dropbear.args
pidfile=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -P)
            pidfile="$2"
            shift 2
            ;;
        *)
            printf '%s\n' "$1" >> /state/dropbear.args
            shift
            ;;
    esac
done
printf '%s\n' "$$" > "$pidfile"
trap 'exit 0' TERM INT HUP QUIT
while :; do
    sleep 1
done
EOF

cat > "$scratch/stubs/dropbear-exit" <<'EOF'
#!/bin/sh
set -eu
pidfile=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -P)
            pidfile="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
printf '%s\n' "$$" > "$pidfile"
exit 42
EOF

chmod +x "$scratch/stubs/dropbear-live" "$scratch/stubs/dropbear-exit"

echo "test: build image"
docker build -t "$tag" "$repo_dir" >/dev/null

echo "test: fail closed without SSH keys"
if docker run --rm --read-only --tmpfs /run --tmpfs /tmp "$tag" >"$scratch/no-keys.out" 2>"$scratch/no-keys.err"; then
    echo "container unexpectedly succeeded without SSH keys" >&2
    exit 1
fi
grep -Fq 'SSH_AUTHORIZED_KEYS must contain at least one valid SSH public key' "$scratch/no-keys.err"

echo "test: SSH works without capabilities and exposes the toolbox environment"
ssh-keygen -q -t ed25519 -N '' -f "$scratch/customer-key" >/dev/null
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    --cap-drop ALL \
    --security-opt no-new-privileges=true \
    -p 127.0.0.1::2222 \
    -e SSH_AUTHORIZED_KEYS="$(cat "$scratch/customer-key.pub")" \
    "$tag"
cid="$CID"
port="$(docker port "$cid" 2222/tcp | sed 's/.*://')"
ssh_ready=0
for _ in $(seq 1 100); do
    if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=1 -i "$scratch/customer-key" -p "$port" root@127.0.0.1 true; then
        ssh_ready=1
        break
    fi
    sleep 0.2
done
[ "$ssh_ready" -eq 1 ] || {
    echo "timed out waiting for customer SSH" >&2
    exit 1
}

ssh -q -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/customer-key" -p "$port" root@127.0.0.1 \
    'printf "SSH_ENV|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$HOME" "$DOCKER_HOST" "$PATH" "$PWD" "$([ -f README.md ] && echo yes || echo no)" "$([ -f AGENTS.md ] && echo yes || echo no)" "$(command -v vi)" "$(command -v vim)" "$(command -v tindbg)"' \
    > "$scratch/ssh-env.out"
grep -Fq 'SSH_ENV|/run/root|unix:///var/run/docker.sock|/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|/run/root|yes|yes|vi|/usr/local/bin/vim|/usr/local/bin/tindbg' "$scratch/ssh-env.out"

ssh -q -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/customer-key" -p "$port" root@127.0.0.1 \
    'grep -E "^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs):" /proc/self/status' \
    > "$scratch/ssh-security.out"
for field in CapInh CapPrm CapEff CapBnd CapAmb; do
    grep -Eq "^${field}:[[:space:]]+0000000000000000$" "$scratch/ssh-security.out"
done
grep -Eq '^NoNewPrivs:[[:space:]]+1$' "$scratch/ssh-security.out"

python3 - "$scratch/customer-key" "$port" <<'PY'
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

key, port = sys.argv[1:]
argv = [
    "ssh", "-tt", "-i", key, "-p", port,
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "root@127.0.0.1",
]
pid, terminal = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

def resize(rows, columns):
    size = struct.pack("HHHH", rows, columns, 0, 0)
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, size)

def read_for(seconds):
    output = bytearray()
    deadline = time.time() + seconds
    while time.time() < deadline:
        readable, _, _ = select.select([terminal], [], [], 0.05)
        if not readable:
            continue
        try:
            data = os.read(terminal, 65536)
        except OSError:
            break
        if not data:
            break
        output.extend(data)
    return bytes(output)

resize(30, 100)
initial = read_for(2)
if b"tinfoil:~#" not in initial:
    raise SystemExit(f"SSH prompt did not appear: {initial!r}")
if b"Tinfoil Containers Debug Shell (BusyBox v1.36.1 - ash)" not in initial:
    raise SystemExit(f"Tinfoil shell banner did not appear: {initial!r}")
if b"built-in shell (ash)" in initial or b"Enter 'help'" in initial:
    raise SystemExit(f"generic BusyBox shell banner appeared: {initial!r}")
for index in range(12):
    resize(30 + index % 2, 80 + index)
    time.sleep(0.05)
after_resize = read_for(1)
os.write(terminal, b"exit\r")
read_for(1)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
if b"tinfoil:~#" in after_resize:
    raise SystemExit(f"SSH resize redrew the prompt: {after_resize!r}")
PY

echo "test: authorized keys reload without restarting Dropbear"
docker exec "$cid" /bin/sh -c 'test ! -e /dev/hvc0 && test ! -e /dev/hvc1'
ssh-keygen -q -t ed25519 -N '' -f "$scratch/support-key" >/dev/null
if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
   -o ConnectTimeout=1 -i "$scratch/support-key" -p "$port" root@127.0.0.1 true; then
    echo "support key unexpectedly authenticated before authorization" >&2
    exit 1
fi
dropbear_pid="$(docker exec "$cid" cat /run/dropbear/dropbear.pid)"
ssh -q -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/customer-key" -p "$port" root@127.0.0.1 \
    'umask 077; cat >> /run/root/.ssh/authorized_keys' < "$scratch/support-key.pub"
ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/support-key" -p "$port" root@127.0.0.1 true
[ "$(docker exec "$cid" cat /run/dropbear/dropbear.pid)" = "$dropbear_pid" ]
ssh -q -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/support-key" -p "$port" root@127.0.0.1 \
    'umask 077; cat > /run/root/.ssh/authorized_keys' < "$scratch/support-key.pub"
if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
   -o ConnectTimeout=1 -i "$scratch/customer-key" -p "$port" root@127.0.0.1 true; then
    echo "customer key unexpectedly authenticated after revocation" >&2
    exit 1
fi
ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/support-key" -p "$port" root@127.0.0.1 true
[ "$(docker exec "$cid" cat /run/dropbear/dropbear.pid)" = "$dropbear_pid" ]

docker exec "$cid" /healthcheck.sh
docker stop -t 2 "$cid" >/dev/null

echo "test: temporary OpenSSH PEM is removed after conversion"
ssh-keygen -q -t ed25519 -N '' -f "$scratch/hostkey" >/dev/null
state_dir="$scratch/state-hostkey"
mkdir -p "$state_dir"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -e SSH_AUTHORIZED_KEYS="$authorized_key" \
    -e SSH_HOST_KEY="$(cat "$scratch/hostkey")" \
    "$tag"
cid="$CID"
wait_for_file "$state_dir/dropbear.args"
docker exec "$cid" /bin/sh -c 'test ! -e /run/dropbear/hostkey.pem'
docker stop -t 2 "$cid" >/dev/null

echo "test: dropbear death fails closed"
state_dir="$scratch/state-dropbear-failclosed"
mkdir -p "$state_dir"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-exit:/usr/local/bin/dropbear:ro" \
    -e SSH_AUTHORIZED_KEYS="$authorized_key" \
    "$tag"
cid="$CID"
status="$(docker wait "$cid")"
[ "$status" = 1 ]
docker logs "$cid" > "$scratch/dropbear-failclosed.log" 2>&1
grep -Fq 'dropbear exited with status 42' "$scratch/dropbear-failclosed.log"

echo "test: healthcheck accepts SSH keys"
docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh "$tag" -c \
    'mkdir -p /run/dropbear /run/root/.ssh &&
     printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
     printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
     printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey comment\n" > /run/root/.ssh/authorized_keys &&
     /healthcheck.sh'

echo "contract tests passed"
