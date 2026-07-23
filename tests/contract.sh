#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ssh-server-contract.XXXXXXXX")"
tag="ssh-server-contract:$(date +%s)"
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

start_container() {
    local cid
    cid="$(docker run -d "$@")"
    containers+=("$cid")
    printf '%s\n' "$cid"
}

start_hvc0() {
    local state_dir="$1"
    local path_file="$state_dir/hvc0.path"
    mkdir -p "$state_dir"
    python3 -c 'import os,pty,time,sys; master, slave = pty.openpty(); print(os.ttyname(slave), flush=True); time.sleep(600)' >"$path_file" &
    helpers+=("$!")
    for _ in $(seq 1 50); do
        if [ -s "$path_file" ]; then
            break
        fi
        sleep 0.2
    done
    [ -s "$path_file" ] || {
        echo "timed out waiting for $path_file" >&2
        return 1
    }
    HVC0_PATH="$(cat "$path_file")"
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

echo "test: fail closed without keys or serial"
if docker run --rm --read-only --tmpfs /run --tmpfs /tmp "$tag" >"$scratch/no-serial.out" 2>"$scratch/no-serial.err"; then
    echo "container unexpectedly succeeded without keys or serial" >&2
    exit 1
fi
grep -Fq 'SSH_AUTHORIZED_KEYS is empty and /dev/hvc0 is unavailable' "$scratch/no-serial.err"

echo "test: serial-only mode restarts and keeps port 2222"
state_dir="$scratch/state-serial"
mkdir -p "$state_dir"
start_hvc0 "$state_dir"
hvc0_path="$HVC0_PATH"
cid="$(start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -v "$hvc0_path:/dev/hvc0" \
    "$tag")"
wait_for_file "$state_dir/dropbear.args"
docker exec "$cid" cat /state/dropbear.args > "$scratch/dropbear.args"
grep -Fxq -- '-p' "$scratch/dropbear.args"
grep -Fxq -- '2222' "$scratch/dropbear.args"
docker exec "$cid" /bin/sh -c 'test ! -e /run/root/.ssh/authorized_keys'
docker exec "$cid" /healthcheck.sh
serial_pid_before="$(docker exec "$cid" cat /run/tinfoil-serial-console.pid)"
docker exec "$cid" /bin/sh -c 'kill -TERM "$(cat /run/tinfoil-serial-console.pid)"'
for _ in $(seq 1 50); do
    serial_pid_after="$(docker exec "$cid" cat /run/tinfoil-serial-console.pid)"
    if [ "$serial_pid_after" != "$serial_pid_before" ]; then
        break
    fi
    sleep 0.2
done
[ "$serial_pid_after" != "$serial_pid_before" ]
docker exec "$cid" /healthcheck.sh
docker stop -t 2 "$cid" >/dev/null

echo "test: temporary OpenSSH PEM is removed after conversion"
ssh-keygen -q -t ed25519 -N '' -f "$scratch/hostkey" >/dev/null
state_dir="$scratch/state-hostkey"
mkdir -p "$state_dir"
start_hvc0 "$state_dir"
hvc0_path="$HVC0_PATH"
cid="$(start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-live:/usr/local/bin/dropbear:ro" \
    -v "$hvc0_path:/dev/hvc0" \
    -e SSH_HOST_KEY="$(cat "$scratch/hostkey")" \
    "$tag")"
wait_for_file "$state_dir/dropbear.args"
docker exec "$cid" /bin/sh -c 'test ! -e /run/dropbear/hostkey.pem'
docker stop -t 2 "$cid" >/dev/null

echo "test: dropbear death fails closed"
state_dir="$scratch/state-failclosed"
mkdir -p "$state_dir"
start_hvc0 "$state_dir"
hvc0_path="$HVC0_PATH"
cid="$(start_container \
    --read-only \
    --tmpfs /run \
    --tmpfs /tmp \
    -v "$state_dir:/state" \
    -v "$scratch/stubs/dropbear-exit:/usr/local/bin/dropbear:ro" \
    -v "$hvc0_path:/dev/hvc0" \
    "$tag")"
status="$(docker wait "$cid")"
[ "$status" = "1" ]
docker logs "$cid" > "$scratch/failclosed.log" 2>&1
grep -Fq 'dropbear exited with status 42' "$scratch/failclosed.log"

echo "test: healthcheck accepts SSH keys without serial"
docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh "$tag" -c \
    'mkdir -p /run/dropbear /run/root/.ssh &&
     printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
     printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
     printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey comment\n" > /run/root/.ssh/authorized_keys &&
     /healthcheck.sh'

echo "test: healthcheck accepts serial-only access and rejects dead serial pid"
start_hvc0 "$scratch/state-health-serial"
hvc0_path="$HVC0_PATH"
docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh \
    -v "$hvc0_path:/dev/hvc0" "$tag" -c \
    'mkdir -p /run/dropbear &&
     printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
     printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
     printf "%s\n" $$ > /run/tinfoil-serial-console.pid &&
     /healthcheck.sh'

start_hvc0 "$scratch/state-health-dead"
hvc0_path="$HVC0_PATH"
if docker run --rm --read-only --tmpfs /run --tmpfs /tmp --entrypoint /bin/sh \
   -v "$hvc0_path:/dev/hvc0" "$tag" -c \
   'mkdir -p /run/dropbear &&
    printf "%s\n" $$ > /run/dropbear/dropbear.pid &&
    printf "host-key\n" > /run/dropbear/dropbear_ed25519_host_key &&
    printf "999999\n" > /run/tinfoil-serial-console.pid &&
    /healthcheck.sh' >"$scratch/healthcheck-dead.out" 2>"$scratch/healthcheck-dead.err"; then
    echo "healthcheck unexpectedly succeeded with dead serial pid" >&2
    exit 1
fi
grep -Fq 'serial console pid 999999 is not running' "$scratch/healthcheck-dead.out"

echo "contract tests passed"
