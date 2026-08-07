# Tinfoil Debug Toolbox Agent Instructions

## Environment

- You are inside the `tinfoil-debug-toolbox` container,
  not the CVM host root filesystem.
- `HOME` and the working directory are `/run/root`.
- The root filesystem is read-only. `/run` and `/tmp` are ephemeral and mounted
  `noexec`.
- There is no supported package manager in this toolbox.
- `vi` and `vim` both invoke the included BusyBox editor.
- Prefer `tindbg boot` for runtime configuration and `tindbg` aliases for status, logs, exec, and disposable
  containers. Direct Docker commands remain available as an escape hatch.
- `DOCKER_HOST=unix:///var/run/docker.sock` grants control over workload
  containers in this debug CVM.
- `tindbg ps`, `inspect`, `logs`, `exec`, and `run` directly invoke the Docker
  CLI. Do not look for equivalent endpoints on `tinfoil-containers`.
- SSH is the toolbox's only interactive access path. Do not create or attach
  serial, HVC, or unauthenticated local shell access.

## Safety

- Inspect before changing: start with `docker ps`, `docker inspect`, and
  `docker logs`.
- Do not stop, remove, rename, or replace `tinfoil-debug-toolbox`; that is the
  toolbox providing the current session.
- Do not assume Docker socket access is equivalent to CVM host-root access. The
  stripped CVM host root is deliberately not mounted here.
- Avoid destructive workload actions unless explicitly requested.
- Never print, copy, or persist secrets from container environments, mounted
  files, or Docker inspection output.
- Prefer noninteractive commands that produce bounded output.

## Workload Discovery

Edit `/run/root/tinfoil-config.debug.yml`, then run `tindbg boot`. This performs
a clean replacement boot: existing managed workloads are removed, runtime
artifacts are regenerated, and shim/egress are restarted by PID 1. To restore
the verified boot configuration, run `tindbg template && tindbg boot`.
`tindbg template` reads `/tinfoil/config.yml`, and `tindbg status` reads
`/tinfoil/container-status.json`; only `tindbg boot` uses the manager socket.

```sh
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker inspect <container>
docker logs --tail=200 <container>
```

Exclude `tinfoil-debug-toolbox` when selecting a workload automatically.
Container names are not guaranteed to resolve from the toolbox's network
namespace. Use `docker exec`, inspect the target IP, or share the target's
network namespace with a temporary diagnostic container.

## Executing Commands

```sh
docker exec <container> <command> [args...]
docker exec -it <container> sh
docker exec -it <container> bash
```

Do not assume a workload includes Bash, Python, curl, jq, or a package manager.
Inspect the image or try the smallest POSIX command first.

## Additional Tools

Do not attempt `apt install` in the toolbox. Launch a disposable container:

```sh
docker run --rm -it ubuntu:24.04 bash
```

For access to a target's localhost listeners:

```sh
docker run --rm -it --network container:<container> ubuntu:24.04 bash
```

Run `apt-get update && apt-get install ...` inside that disposable container.
For repeatable or security-sensitive work, use a pinned purpose-built image
instead of installing interactively.

## NVIDIA

The toolbox itself has no GPU device authority. Prefer inspecting an existing
GPU workload:

```sh
docker exec <container> nvidia-smi
```

Or launch the smallest standalone check through the generated CDI device:

```sh
docker run --rm --device=nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

If no CDI device exists, report that the deployment has no assigned GPU or that
GPU bootstrap did not complete; do not broaden device access manually.

## Persistence

- `/run/root`, shell history, keys, and downloaded files disappear when the
  toolbox is recreated.
- Workload container writable layers persist only until those containers are
  recreated.
- Use a Docker image, mounted data volume, or external artifact store for
  anything that must be repeatable or durable.
