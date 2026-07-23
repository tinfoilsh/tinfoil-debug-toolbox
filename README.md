# Tinfoil Debug Toolbox

This image is the measured debug SSH endpoint injected by `tinfoild` when a
CVM is launched in debug mode.

SSH lands inside this toolbox container, not inside the stripped CVM host
rootfs. The toolbox contains Dropbear, BusyBox `/bin/sh`, the Docker CLI, and a
few small helpers for inspecting workload containers.

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

If `/dev/hvc0` exists, PID 1 also keeps an unauthenticated BusyBox root serial
shell alive on that console. In that case `SSH_AUTHORIZED_KEYS` may be empty.
Without `/dev/hvc0`, the container fails closed unless at least one valid SSH
public key is present.

Typical runtime shape:

```sh
docker run --read-only \
  --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add SETUID --cap-add SETGID \
  -p 2222:2222 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  <image>
```
