# Tinfoil Debug Toolbox

This image is the measured debug toolbox injected by `tinfoild` when a CVM is
launched in user-debug mode.

Customer SSH lands inside this toolbox container, not inside the stripped CVM
host rootfs. The toolbox contains Dropbear, a quiet static BusyBox `/bin/sh`,
the Docker CLI, and `tindbg`.

Useful commands:

```sh
tindbg boot
tindbg status
tindbg template && tindbg boot  # restore verified boot config
tindbg ps
tindbg logs <container>
tindbg exec -it <container> sh

docker pull <image>
docker run ...
docker ps
docker logs <container>
docker inspect <container>
docker exec -it <container> sh
docker exec <container> nvidia-smi
```

`tindbg ps`, `inspect`, `logs`, `exec`, and `run` are deliberately thin aliases
for the included Docker CLI over `/var/run/docker.sock`. They do not add exec,
TTY, resize, log-streaming, or diagnostic-container code to `tinfoil-containers`.
Only `tindbg boot` calls the debug manager socket.

Each session starts in `/run/root` with `README.md` for humans and `AGENTS.md`
for coding agents. They explain workload discovery, container networking,
disposable diagnostic containers, the included `vi`/`vim` editor, and the
minimal NVIDIA CDI smoke command.

The toolbox talks to Docker through `/var/run/docker.sock`. That is a powerful
debug capability: anyone with SSH access can control workload containers inside
that CVM. The image intentionally does not require `/host`, host PID namespace,
host systemd, or a shell installed in the CVM host rootfs.

Dropbear listens on port `2222` by default so this endpoint does not assume
host networking or require any added Linux capabilities. The image accepts
root sessions only when the process already has the expected root user and
group state.

The image assumes a read-only root filesystem with writable tmpfs mounts for
`/run` and `/tmp`. Root's home directory lives at `/run/root`, so host keys,
authorized keys, pidfiles, shell history, and the session documentation stay in
tmpfs. The tmpfs mounts are `noexec`; install additional packages in a separate
diagnostic container rather than modifying the toolbox.

At least one valid customer SSH public key is required. The toolbox does not
open an HVC, serial, or unauthenticated local shell access path.

Typical runtime shape:

```sh
docker run --read-only \
  --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges=true \
  -p 2222:2222 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  <image>
```
