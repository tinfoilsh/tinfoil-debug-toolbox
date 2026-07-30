# Tinfoil Containers Debug Shell

This shell runs inside the measured debug toolbox container. It is not a shell
on the CVM host root filesystem.

Both `vi` and `vim` are available. They use BusyBox `vi`; full Vim is not
installed in this scratch image.

The toolbox has the Docker CLI and access to `/var/run/docker.sock`. That socket
grants control over the workload containers in this debug CVM. Commands such as
`docker exec`, `docker stop`, and `docker rm` directly affect the deployment.

## Inspect workloads

```sh
docker ps
docker logs --tail=200 <container>
docker inspect <container>
docker exec -it <container> sh
```

If the target image has Bash but no `sh`, use `bash`. For a noninteractive
command, omit `-it`:

```sh
docker exec <container> env
docker exec <container> curl -fsS http://127.0.0.1:8080/health
```

To find a container's addresses and published ports:

```sh
docker inspect -f '{{json .NetworkSettings.Networks}}' <container>
docker port <container>
```

The most reliable way to reach a service is usually `docker exec` from inside
its own network namespace. For separate diagnostic tooling, launch a temporary
container that shares the target's network namespace:

```sh
docker run --rm -it --network container:<container> ubuntu:24.04 bash
```

## Check NVIDIA GPUs

The toolbox itself is intentionally GPU-unprivileged. Launch a disposable CUDA
container with the CVM's generated NVIDIA CDI device:

```sh
docker run --rm --device=nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

To inspect a workload that already has GPU access:

```sh
docker exec <container> nvidia-smi
```

## Install additional tools

The toolbox is read-only and intentionally has no APT package database or
package manager. `/run` and `/tmp` are temporary `noexec` filesystems, so this
container is not an installation target.

Install tools inside a disposable diagnostic container instead:

```sh
docker run --rm -it ubuntu:24.04 bash
apt-get update
apt-get install -y curl jq strace
```

To diagnose a workload's localhost services, combine this with its network
namespace:

```sh
docker run --rm -it --network container:<container> ubuntu:24.04 bash
```

Changes in the toolbox home directory disappear when the toolbox container is
recreated. Build or pull a dedicated diagnostic image for repeatable tooling.

See `AGENTS.md` for operational instructions intended for coding agents.
