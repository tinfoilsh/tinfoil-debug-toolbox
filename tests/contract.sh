#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ssh-server-contract.XXXXXXXX")"
tag="ssh-server-contract:$(date +%s)"
authorized_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey contract'
containers=()
helpers=()

cleanup() {
    if [ "${#containers[@]}" -gt 0 ]; then
        docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
    fi
    if [ "${#helpers[@]}" -gt 0 ]; then
        kill "${helpers[@]}" >/dev/null 2>&1 || true
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

wait_for_pattern() {
    local pattern="$1"
    local path="$2"
    for _ in $(seq 1 100); do
        if grep -Fq "$pattern" "$path" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    echo "timed out waiting for $pattern in $path" >&2
    cat "$path" >&2 || true
    return 1
}

start_container() {
    CID="$(docker run -d "$@")"
    containers+=("$CID")
}

start_pty() {
    local state_dir="$1"
    local name="$2"
    local path_file="$state_dir/$name.path"
    local input_fifo="$state_dir/$name.in"
    local output_file="$state_dir/$name.out"

    mkdir -p "$state_dir"
    mkfifo "$input_fifo"
    : > "$output_file"
    python3 "$scratch/pty_bridge.py" "$path_file" "$input_fifo" "$output_file" &
    helpers+=("$!")
    wait_for_file "$path_file"
    PTY_PATH="$(cat "$path_file")"
    PTY_INPUT="$input_fifo"
    PTY_OUTPUT="$output_file"
}

cat > "$scratch/pty_bridge.py" <<'PY'
import os
import pty
import select
import sys
import time

path_file, input_fifo, output_file = sys.argv[1:]
master, slave = pty.openpty()
with open(path_file, "w", encoding="utf-8") as stream:
    stream.write(os.ttyname(slave))
    stream.flush()

os.set_blocking(master, False)
input_fd = os.open(input_fifo, os.O_RDWR | os.O_NONBLOCK)
output_fd = os.open(output_file, os.O_WRONLY | os.O_APPEND)

while True:
    readable, _, _ = select.select([master, input_fd], [], [], 1)
    for source in readable:
        try:
            data = os.read(source, 4096)
        except OSError:
            time.sleep(0.05)
            continue
        if not data:
            continue
        os.write(output_fd if source == master else master, data)
PY

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

cat > "$scratch/stubs/toolbox-shell-exit" <<'EOF'
#!/bin/sh
exit 42
EOF

chmod +x "$scratch/stubs/dropbear-live" "$scratch/stubs/dropbear-exit" "$scratch/stubs/toolbox-shell-exit"

echo "test: build image"
docker build -t "$tag" "$repo_dir" >/dev/null

echo "test: fail closed without keys or hvc1"
if docker run --rm --read-only --tmpfs /run --tmpfs /tmp "$tag" >"$scratch/no-console.out" 2>"$scratch/no-console.err"; then
    echo "container unexpectedly succeeded without keys or hvc1" >&2
    exit 1
fi
grep -Fq 'SSH_AUTHORIZED_KEYS is empty and /dev/hvc1 toolbox console is unavailable' "$scratch/no-console.err"

echo "test: hvc0 never enables the toolbox console"
start_pty "$scratch/state-hvc0-only" hvc0
hvc0_path="$PTY_PATH"
if docker run --rm --read-only --tmpfs /run --tmpfs /tmp \
   -v "$hvc0_path:/dev/hvc0" "$tag" >"$scratch/hvc0-only.out" 2>"$scratch/hvc0-only.err"; then
    echo "container unexpectedly accepted hvc0 as the toolbox console" >&2
    exit 1
fi
grep -Fq 'SSH_AUTHORIZED_KEYS is empty and /dev/hvc1 toolbox console is unavailable' "$scratch/hvc0-only.err"

state_dir="$scratch/state-hvc0-with-key"
mkdir -p "$state_dir"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -v "$hvc0_path:/dev/hvc0" \
    -e SSH_AUTHORIZED_KEYS="$authorized_key" \
    "$tag"
cid="$CID"
wait_for_file "$state_dir/dropbear.args"
docker exec "$cid" test ! -e /run/tinfoil-toolbox-console.pid
docker exec "$cid" /healthcheck.sh
docker stop -t 2 "$cid" >/dev/null

echo "test: hvc1 must be a usable character terminal"
: > "$scratch/not-a-device"
if docker run --rm --read-only --tmpfs /run --tmpfs /tmp \
   -v "$scratch/not-a-device:/dev/hvc1" \
   -e SSH_AUTHORIZED_KEYS="$authorized_key" \
   "$tag" >"$scratch/not-char.out" 2>"$scratch/not-char.err"; then
    echo "container unexpectedly accepted a regular hvc1 file" >&2
    exit 1
fi
grep -Fq '/dev/hvc1 exists but is not a character device' "$scratch/not-char.err"

if docker run --rm --read-only --tmpfs /run --tmpfs /tmp \
   -v /dev/null:/dev/hvc1 \
   -e SSH_AUTHORIZED_KEYS="$authorized_key" \
   "$tag" >"$scratch/not-tty.out" 2>"$scratch/not-tty.err"; then
    echo "container unexpectedly accepted a non-terminal hvc1 device" >&2
    exit 1
fi
grep -Fq '/dev/hvc1 is not a usable terminal' "$scratch/not-tty.err"

echo "test: SSH and hvc1 share toolbox environment; hvc1 has a controlling PTY"
ssh-keygen -q -t ed25519 -N '' -f "$scratch/customer-key" >/dev/null
start_pty "$scratch/state-shared" hvc1
hvc1_path="$PTY_PATH"
hvc1_input="$PTY_INPUT"
hvc1_output="$PTY_OUTPUT"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -p 127.0.0.1::2222 \
    -v "$hvc1_path:/dev/hvc1" \
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
wait_for_pattern 'tinfoil:~#' "$hvc1_output"
! grep -Fq 'tinfoil-debug-toolbox:' "$hvc1_output"

ssh -q -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$scratch/customer-key" -p "$port" root@127.0.0.1 \
    'printf "SSH_ENV|%s|%s|%s|%s|%s\n" "$HOME" "$DOCKER_HOST" "$PATH" "$PWD" "$(command -v tinfoil-help)"' \
    > "$scratch/ssh-env.out"
grep -Fq 'SSH_ENV|/run/root|unix:///var/run/docker.sock|/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|/run/root|/usr/local/bin/tinfoil-help' "$scratch/ssh-env.out"
! grep -Fq 'Welcome to the Tinfoil debug toolbox.' "$scratch/ssh-env.out"

printf '%s\r' \
    'printf "CONSOLE_ENV|%s|%s|%s|%s|%s|%s|%s\n" "$HOME" "$DOCKER_HOST" "$PATH" "$PWD" "$(command -v tinfoil-help)" "$([ -t 0 ] && echo yes || echo no)" "$(if exec 3<>/dev/tty; then [ -t 3 ] && echo yes || echo no; else echo no; fi)"' \
    > "$hvc1_input"
wait_for_pattern 'CONSOLE_ENV|/run/root|unix:///var/run/docker.sock|/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|/run/root|/usr/local/bin/tinfoil-help|yes|yes' "$hvc1_output"
! grep -Fq 'Welcome to the Tinfoil debug toolbox.' "$hvc1_output"
docker exec "$cid" /healthcheck.sh
docker stop -t 2 "$cid" >/dev/null

echo "test: ordinary console logout restarts"
state_dir="$scratch/state-logout"
mkdir -p "$state_dir"
start_pty "$state_dir" hvc1
hvc1_path="$PTY_PATH"
hvc1_input="$PTY_INPUT"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -v "$hvc1_path:/dev/hvc1" \
    "$tag"
cid="$CID"
wait_for_file "$state_dir/dropbear.args"
console_pid="$(docker exec "$cid" cat /run/tinfoil-toolbox-console.pid)"
printf 'exit\r' > "$hvc1_input"
sleep 2
[ "$(docker inspect -f '{{.State.Running}}' "$cid")" = true ]
[ "$(docker exec "$cid" cat /run/tinfoil-toolbox-console.pid)" = "$console_pid" ]
docker exec "$cid" /healthcheck.sh
docker stop -t 2 "$cid" >/dev/null

echo "test: repeated immediate console failures fail closed"
state_dir="$scratch/state-console-failures"
mkdir -p "$state_dir"
start_pty "$state_dir" hvc1
hvc1_path="$PTY_PATH"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -v "$scratch/stubs/toolbox-shell-exit:/usr/local/bin/toolbox-shell:ro" \
    -v "$hvc1_path:/dev/hvc1" \
    "$tag"
cid="$CID"
status="$(docker wait "$cid")"
[ "$status" = 1 ]
docker logs "$cid" > "$scratch/console-failures.log" 2>&1
grep -Fq 'toolbox console shell repeatedly failed immediately' "$scratch/console-failures.log"
grep -Fq 'toolbox console supervisor exited with status 1' "$scratch/console-failures.log"

echo "test: unexpected console supervisor death is fatal"
state_dir="$scratch/state-supervisor-death"
mkdir -p "$state_dir"
start_pty "$state_dir" hvc1
hvc1_path="$PTY_PATH"
start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -v "$hvc1_path:/dev/hvc1" \
    "$tag"
cid="$CID"
wait_for_file "$state_dir/dropbear.args"
docker exec "$cid" /bin/sh -c 'kill -KILL "$(cat /run/tinfoil-toolbox-console.pid)"'
status="$(docker wait "$cid")"
[ "$status" = 1 ]
docker logs "$cid" > "$scratch/supervisor-death.log" 2>&1
grep -Fq 'toolbox console supervisor exited with status 137' "$scratch/supervisor-death.log"

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

echo "test: healthcheck accepts SSH keys without console"
docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh "$tag" -c \
    'mkdir -p /run/dropbear /run/root/.ssh &&
     printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
     printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
     printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey comment\n" > /run/root/.ssh/authorized_keys &&
     /healthcheck.sh'

echo "test: healthcheck requires a live hvc1 supervisor"
start_pty "$scratch/state-health-console" hvc1
hvc1_path="$PTY_PATH"
docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh \
    -v "$hvc1_path:/dev/hvc1" "$tag" -c \
    'mkdir -p /run/dropbear &&
     printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
     printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
     printf "%s\n" $$ > /run/tinfoil-toolbox-console.pid &&
     /healthcheck.sh'

if docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh \
   -v "$hvc1_path:/dev/hvc1" "$tag" -c \
   'mkdir -p /run/dropbear &&
    printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
    printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
    printf "999999\n" > /run/tinfoil-toolbox-console.pid &&
    /healthcheck.sh' >"$scratch/healthcheck-dead.out" 2>"$scratch/healthcheck-dead.err"; then
    echo "healthcheck unexpectedly succeeded with dead console supervisor" >&2
    exit 1
fi
grep -Fq 'toolbox console pid 999999 is not running' "$scratch/healthcheck-dead.out"

echo "contract tests passed"
