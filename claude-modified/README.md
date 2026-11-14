# Claude Code + Antigravity CLI Sandbox

Custom docker image that extends `docker/sandbox-templates:claude-code`.

## What's included

| Layer | What it provides |
|---|---|
| `docker/sandbox-templates:claude-code` | Ubuntu base, Git, Node.js, Go, Python 3, Docker CLI, non-root user with sudo |
| This image | `glab` (GitLab CLI) in `/usr/local/bin`, CodeGraph CLI |

## Build & Load Template

To build the image, save it to a tar file, and load it into `sbx`:

```bash
# Uses default tag 'latest' -> claude-code-modified:latest & claude-modified-latest.tar
./build_and_load.sh

# Or specify a custom tag:
./build_and_load.sh v1.0.0
```

Or manually:

```bash
docker build -t claude-code-modified:latest .
docker image save claude-code-modified:latest -o claude-modified-latest.tar
sbx template load claude-modified-latest.tar
```

## Run with Docker Sandbox CLI

```bash
sbx run --template claude-code-modified:latest claude
```

## CodeGraph Integration

This sandbox includes CodeGraph pre-installed for advanced semantic code search and dependency mapping.

**First-time setup:**
Upon logging into the container for the first time, perform these steps in order:
1. Run `codegraph-setup`

## SBX Network Policy Allowlisting

Building and running this image inside Docker Sandbox (`sbx`) requires outbound HTTPS access to specific registries and download mirrors.

All required domains are defined in [`sbx-policy.yaml`](sbx-policy.yaml).

### Apply network rules via script

Use [`apply_policy.sh`](apply_policy.sh) to apply the network rules:

```bash
# 1. Global Mode (Default - applies rules across all sandboxes)
./apply_policy.sh --global

# 2. Project/Sandbox Mode (Applies rules to a specific sandbox)
./apply_policy.sh --sandbox my-project-sandbox

# 3. Dry-run Mode (Preview sbx commands without executing)
./apply_policy.sh --dry-run
```

### Whitelisted Domains (`sbx-policy.yaml`)

| Category | Domain Patterns | Purpose |
|---|---|---|
| **Docker Hub & Registry** | `docker.io`, `*.docker.io`, `docker.com`, `*.docker.com`, `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `production.cloudfront.docker.com` | Base image layer downloads and container auth |
| **Google** | `google.com` | google |
| **Claude & Anthropic** | `claude.ai`, `claude.com`, `*.claude.com`, `anthropic.com`, `api.anthropic.com` | Claude AI interface & Anthropic API access |
| **GitHub** | `github.com`, `*.github.com`, `*.githubusercontent.com`, `raw.githubusercontent.com` | CodeGraph scripts, source code, and release assets |
| **GitLab & Linux Mirrors** | `gitlab.com`, `*.gitlab.com`, `ports.ubuntu.com` | `glab` CLI releases and Ubuntu package repositories |

