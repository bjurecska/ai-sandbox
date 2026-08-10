# Claude Code + Antigravity CLI Sandbox

Docker image that extends `docker/sandbox-templates:claude-code` with the
[Google Antigravity CLI](https://antigravity.google) (`agy`) pre-installed,
so Claude Code can delegate tasks to `agy` from inside the sandbox.

## What's included

| Layer | What it provides |
|---|---|
| `docker/sandbox-templates:claude-code` | Ubuntu base, Git, Node.js, Go, Python 3, Docker CLI, non-root user with sudo |
| This image | `agy` binary in `~/.local/bin`, `glab` (GitLab CLI) in `/usr/local/bin`, CodeGraph CLI, pre-seeded `~/.gemini/config` |

## Build & Load Template

To build the image, save it to a tar file, and load it into `sbx`:

```bash
# Uses default tag 'latest' -> claude-code-agy:latest & claude-agy-latest.tar
./build_and_load.sh

# Or specify a custom tag:
./build_and_load.sh v1.0.0
```

Or manually:

```bash
docker build -t claude-code-agy:latest .
docker image save claude-code-agy:latest -o claude-agy-latest.tar
sbx template load claude-agy-latest.tar
```

## Run with Docker Sandbox CLI

```bash
sbx run --template claude-code-agy:latest claude
```

## How Claude calls agy

Once inside the sandbox, Claude can invoke agy in non-interactive mode:

```bash
# Web search
agy -p "search the web for the latest Docker security advisories"

# File mapping / codebase exploration
agy -p "give me a file map of this project"

# Quick research
agy -p "explain what this function does" -f src/main.go
```

## CodeGraph Integration

This sandbox includes CodeGraph pre-installed for advanced semantic code search and dependency mapping.

**First-time setup:**
Because the CodeGraph MCP server registers itself with `agy`, you must run the setup script *after* `agy` is fully initialized and logged in.

Upon logging into the container for the first time, perform these steps in order:
1. Run `agy login`
2. Run `codegraph-setup`

*Note: The `codegraph` MCP tools are already pre-approved in `agy`'s settings, so the agent can invoke them immediately without interactive prompts.*

## Authentication

The `agy` binary requires a Google API key at runtime. Set it as a sandbox
secret so it's injected without baking credentials into the image:

```bash
sbx secret set GEMINI_API_KEY <your-key>
```

## Pre-seeded Config & Custom Skills (agy)

The container build pre-seeds configuration files exclusively for the **Google Antigravity CLI (`agy`)**:

- **System Rules**: [`config/agy/GEMINI.md`](config/agy/GEMINI.md) sets system-level rules for `agy` and is copied to `/home/agent/.gemini/config/GEMINI.md` and `/root/.gemini/config/GEMINI.md`.
- **Settings & Terms Bypass**: [`config/agy/settings.json`](config/agy/settings.json), `onboarding.json`, and `terms.json` pre-configure `hasCompletedOnboarding: true`, `hasAcceptedTerms: true`, `terminalChoice: "xterm-256color"`, `renderingMode: "alt-screen"`, read-only permission allow rules (`read_file(**)`, `search_web(**)`, `list_dir(**)`, `grep_search(**)`), and pre-approved CodeGraph MCP tools (`mcp_codegraph_*`, `codegraph_*`). This suppresses initial terms of usage and terminal choice prompts for both `agent` and `root` users.
- **Workspace Trust**: `agy` matches `trustedWorkspaces` entries as literal absolute paths — glob patterns are not supported. Because the workspace path inside the sandbox mirrors the host project path, it cannot be baked into the image; instead [`scripts/agy-trust-workspace`](scripts/agy-trust-workspace) (installed at `/usr/local/bin`) appends the shell's starting directory to `~/.gemini/antigravity-cli/settings.json` on interactive login, so the "Do you trust the contents of this project?" dialog never appears for the sandbox workspace.
- **Skills**: Skill folders under [`config/agy/skills/`](config/agy/skills/) (such as `buildah-docker-build`) are automatically copied to `/home/agent/.gemini/config/skills/`, `/home/agent/.gemini/antigravity-cli/builtin/skills/`, `/root/.gemini/config/skills/`, and `/root/.gemini/antigravity-cli/builtin/skills/`.
- **Logon & Exec Banner**: Installs `/etc/profile.d/banner.sh` hooked into `/etc/bash.bashrc`, `/etc/profile`, `~/.bashrc`, and `~/.profile` for both `agent` and `root` users, ensuring the first login setup instructions banner is displayed upon `docker exec` into the container.


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
| **Google & Antigravity** | `antigravity.google`, `antigravity-unleash.goog`, `*.antigravity-unleash.goog`, `*-974169037036.*.run.app`, `run.app`, `*.run.app`, `google.com`, `*.googleapis.com`, `*.googleusercontent.com` | Installer scripts, Gemini APIs, Unleash service, auto-updaters, & assets |
| **Claude & Anthropic** | `claude.ai`, `claude.com`, `*.claude.com`, `anthropic.com`, `api.anthropic.com` | Claude AI interface & Anthropic API access |
| **GitHub** | `github.com`, `*.github.com`, `*.githubusercontent.com`, `raw.githubusercontent.com` | CodeGraph scripts, source code, and release assets |
| **GitLab & Linux Mirrors** | `gitlab.com`, `*.gitlab.com`, `ports.ubuntu.com` | `glab` CLI releases and Ubuntu package repositories |

