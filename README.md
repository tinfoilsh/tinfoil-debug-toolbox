# Tinfoil Debug Toolbox

This image is the measured debug SSH endpoint injected by `tinfoild` when a
CVM is launched in debug mode.

SSH lands inside this toolbox container, not inside the stripped CVM host
rootfs. The toolbox contains Dropbear, BusyBox `/bin/sh`, the Docker CLI, and a
few small helpers for inspecting workload containers.

Useful commands:

```sh
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
