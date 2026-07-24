# Tinfoil Debug Toolbox

This image is the measured debug toolbox injected by `tinfoild` when a CVM is
launched in user-debug mode.

Customer SSH and the optional operator console both land inside this toolbox
container, not inside the stripped CVM host rootfs. The toolbox contains
Dropbear, BusyBox `/bin/sh`, the Docker CLI, and a few small helpers for
inspecting workload containers.

Useful commands:

```sh
docker pull <image>
docker run ...
docker ps
docker logs <container>
docker inspect <container>
docker exec -it <container> sh
docker exec <container> nvidia-smi
tinfoil-help
```

The toolbox talks to Docker through `/var/run/docker.sock`. That is a powerful
debug capability: anyone with SSH access can control workload containers inside
that CVM. The image intentionally does not require `/host`, host PID namespace,
host systemd, or a shell installed in the CVM host rootfs.

Dropbear listens on port `2222` by default so this endpoint does not assume
host networking and does not require `NET_BIND_SERVICE`. When container
capabilities are trimmed, the documented runtime requirement is `SETUID` and
`SETGID` only.

The image assumes a read-only root filesystem with writable tmpfs mounts for
`/run` and `/tmp`. Root's home directory lives at `/run/root`, so host keys,
authorized keys, pidfiles, and shell history stay in tmpfs.

If the exact `/dev/hvc1` device is present, PID 1 also keeps an unauthenticated
BusyBox root shell attached to that fixed operator console. `/dev/hvc0` is
never used by this image; it remains reserved for CVM boot logging and the
compile-time debug-image shell.

The toolbox validates that `/dev/hvc1` is both a character device and a usable
terminal. A present but invalid device fails startup clearly. The console
shares SSH's `/run/root` home and working directory, Docker environment,
`PATH`, and toolbox helpers. Ordinary logout restarts the console shell, while
repeated immediate exits or loss of its supervisor fail the container closed.

When `/dev/hvc1` is available, `SSH_AUTHORIZED_KEYS` may be empty because the
operator console supplies the access path. Without `/dev/hvc1`, at least one
valid customer SSH public key is required.

Typical runtime shape:

```sh
docker run --read-only \
  --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add SETUID --cap-add SETGID \
  -p 2222:2222 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --device /dev/hvc1:/dev/hvc1 \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  <image>
```

The `/dev/hvc1` mapping is optional and fixed. Do not substitute `/dev/hvc0`
or make the console device configurable.
