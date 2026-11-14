---
name: buildah-docker-build
description: >-
  Build Docker/OCI container images inside the Claude Code sandbox using
  buildah. Use this skill whenever you need to build a container image from a
  Dockerfile. The sandbox cannot run a Docker daemon, so buildah with vfs
  storage and chroot isolation is the supported alternative.
---

# Building Container Images with Buildah

This sandbox **cannot run `docker build`** — it lacks the kernel capabilities
(`SYS_ADMIN`, `NET_ADMIN`) required by the Docker daemon. Use **buildah**
instead, which is pre-installed and pre-configured.

---

## Quick Reference

### Build an image from a Dockerfile

```bash
sudo buildah --storage-driver vfs build \
  --isolation chroot \
  -t <image-name>:<tag> \
  -f <Dockerfile-path> \
  <context-dir>
```

### Example

```bash
sudo buildah --storage-driver vfs build \
  --isolation chroot \
  -t myapp:latest \
  -f ./Dockerfile \
  .
```

### List images

```bash
sudo buildah --storage-driver vfs images
```

### Push an image to a registry

```bash
sudo buildah --storage-driver vfs push <image> docker://<registry>/<repo>:<tag>
```

### Export an image as a tarball

```bash
sudo buildah --storage-driver vfs push <image> oci-archive:/path/to/output.tar
```

### Remove an image

```bash
sudo buildah --storage-driver vfs rmi <image>
```

### List / remove build containers

```bash
sudo buildah --storage-driver vfs containers
sudo buildah --storage-driver vfs rm --all
```

---

## Required Flags

| Flag | Why |
|---|---|
| `sudo` | The sandbox kernel blocks `setgroups()` for unprivileged users, which buildah needs for `RUN` steps. |
| `--storage-driver vfs` | The `overlay2` driver requires `mount()` which needs `SYS_ADMIN`. `vfs` works without it (slower, copies full layers). |
| `--isolation chroot` | Full container isolation (`oci`) requires namespace support the sandbox lacks. `chroot` is sufficient for image builds. |

---

## Without sudo (limited)

If your Dockerfile has **no `RUN` steps** (only `FROM`, `COPY`, `ADD`, `ENV`,
`CMD`, `ENTRYPOINT`, `LABEL`, etc.), you can build without sudo:

```bash
buildah build --isolation chroot -t <image>:<tag> .
```

For Dockerfiles with `RUN` steps, `sudo` is required.

---

## Rootless operations (no sudo needed)

These commands work without sudo:

```bash
# Create a working container from a base image
buildah from --isolation chroot docker.io/library/alpine:latest

# Copy files into a container
buildah copy <container-name> <src> <dest>

# Set config (CMD, ENV, ENTRYPOINT, etc.)
buildah config --cmd '["my-command"]' <container-name>

# Commit to an image
buildah commit <container-name> localhost/my-image:latest

# List images
buildah images
```

---

## Network Policy Requirements

To pull base images from Docker Hub, the sandbox network policy must allow:

| Domain | Purpose |
|---|---|
| `registry-1.docker.io` | Docker Hub registry API (manifests, auth) |
| `auth.docker.io` | Docker Hub authentication tokens |
| `production.cloudflare.docker.com` | Docker Hub blob/layer CDN |

For other registries (ghcr.io, gcr.io, quay.io, etc.), their domains must
also be allowed in the network policy.

---

## Common Patterns

### Multi-stage build

```bash
sudo buildah --storage-driver vfs build \
  --isolation chroot \
  --target builder \
  -t myapp:builder \
  .
```

### Build with build args

```bash
sudo buildah --storage-driver vfs build \
  --isolation chroot \
  --build-arg VERSION=1.0.0 \
  -t myapp:1.0.0 \
  .
```

### Build and save as Docker-compatible tarball

```bash
sudo buildah --storage-driver vfs build \
  --isolation chroot \
  -t myapp:latest \
  .

sudo buildah --storage-driver vfs push \
  myapp:latest \
  docker-archive:myapp.tar
```

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `error setting supplemental groups list` | Missing `sudo` | Add `sudo` before the command |
| `overlay mount ... operation not permitted` | Wrong storage driver | Add `--storage-driver vfs` |
| `Blocked by network policy: domain ...` | Registry domain not allowed | Add the domain to the sandbox network policy allowlist |
| `potentially insufficient UIDs or GIDs` | Running without sudo | Use `sudo` for Dockerfiles with `RUN` steps |
| `mount source ... operation not permitted` | Missing `--isolation chroot` | Add `--isolation chroot` |
