# Sandboxed Docker Templates Repository

This repository contains Docker sandbox templates and scripts for building and managing container environments with [`sbx`](https://docs.docker.com/).

## Repository Structure

```text
/Users/aiworker/git/sandboxed-docker/
├── .codegraph/                  # CodeGraph index
├── .gitignore                   # Git ignore rules
├── build_and_load.sh            # Root build & load script for projects
├── apply_policy.sh              # Root SBX network policy synchronization script
├── sbx-policy-global.yaml       # Global baseline network policy manifest
├── README.md                    # Repository documentation
└── claude-agy/                  # Claude Code + Google Antigravity CLI Sandbox Template
    ├── Dockerfile
    ├── README.md                # Project-specific documentation
    ├── sbx-policy.yaml          # Project-specific SBX network policy manifest
    └── config/                  # Gemini system rules and skills
```

---

## Sandbox Projects

### 1. [`claude-agy/`](claude-agy/)
Extends `docker/sandbox-templates:claude-code` with Google Antigravity CLI (`agy`), CodeGraph CLI, and GitLab CLI (`glab`) pre-installed for agentic workflows inside Docker sandboxes.

👉 Read the full project documentation in [`claude-agy/README.md`](claude-agy/README.md).

---

## End-to-End Quickstart Workflow

Follow these steps to build the template, synchronize network egress policies for your sandbox instance, and launch Claude Code:

1. **Build and Load the Sandbox Template**:
   ```bash
   ./build_and_load.sh claude-agy
   ```
   *Builds the image, exports a tar archive, loads it into `sbx`, and applies global network policy baselines.*

2. **Run the Sandboxed Container**:
   ```bash
   sbx run --template claude-code-agy:latest --name sandboxed-claude-agy claude
   ```

3. **Apply Network Policy to the Sandbox Instance**:
   ```bash
   ./apply_policy.sh claude-agy --sandbox sandboxed-claude-agy
   ```
   *Applies project-specific network allowlist rules from `claude-agy/sbx-policy.yaml` (and global baseline policies) to `sandboxed-claude-agy`.*

---

## Network Policies & Egress Controls (`apply_policy.sh`)

Docker Sandbox (`sbx`) enforces strict outbound network isolation. `apply_policy.sh` manages egress domain permissions by reading YAML policy manifests and executing **two-way policy synchronization** (automatically adding missing allowed domains and revoking unmanifested domains).

### Policy Manifest Hierarchy
- **Global Policy Manifest**: [`sbx-policy-global.yaml`](sbx-policy-global.yaml) – Baseline network rules required across all sandboxes (Docker Hub registry & auth endpoints).
- **Project Policy Manifest**: [`claude-agy/sbx-policy.yaml`](claude-agy/sbx-policy.yaml) – Domain rules required for `claude-agy` tooling (Google Antigravity, Claude/Anthropic APIs, GitHub, GitLab, Ubuntu packages).

### Network Rules Summary

| Domain Category | Whitelisted Domains / Patterns | Purpose & Scope |
|---|---|---|
| **Docker Registries** | `docker.com`, `*.docker.com`, `docker.io`, `*.docker.io`, `production.cloudflare.docker.com`, `production.cloudfront.docker.com` | Base image layer retrieval, authentication, and CDN access |
| **Google & Antigravity** | `antigravity.google`, `antigravity-unleash.goog`, `*.antigravity-unleash.goog`, `*.run.app`, `google.com`, `*.googleapis.com`, `*.googleusercontent.com` | Antigravity CLI installer, Gemini API models, Unleash backend, updaters |
| **Claude & Anthropic** | `claude.ai`, `claude.com`, `*.claude.com`, `anthropic.com`, `api.anthropic.com` | Claude AI interactive environment and Anthropic API endpoints |
| **GitHub Ecosystem** | `github.com`, `*.github.com`, `*.githubusercontent.com`, `raw.githubusercontent.com` | CodeGraph scripts, Git remotes, and repository releases |
| **GitLab & Linux Mirrors** | `gitlab.com`, `*.gitlab.com`, `ports.ubuntu.com` | `glab` CLI releases and Ubuntu package repositories (`apt`) |

### `apply_policy.sh` Usage Options

```bash
# Apply network policies to a specific named sandbox instance (Recommended)
./apply_policy.sh claude-agy --sandbox sandboxed-claude-agy

# Synchronize global policy baselines across all sandboxes
./apply_policy.sh --global

# Synchronize global policies using a project policy file
./apply_policy.sh claude-agy --global

# Dry-run mode (preview allow/revoke commands without executing)
./apply_policy.sh claude-agy --sandbox sandboxed-claude-agy --dry-run
```

---

## Building and Loading Projects (`build_and_load.sh`)

The root `build_and_load.sh` script automates the full template generation workflow:
1. Applies project network policies to `sbx` via `apply_policy.sh`.
2. Builds the container image using `buildah` (or `docker`).
3. Saves the image tarball to `<project_dir>/<project>-<tag>.tar`.
4. Loads the template into `sbx template load`.

### Usage

```bash
# Build and load 'claude-agy' project with default tag 'latest'
./build_and_load.sh claude-agy

# Build with a custom tag (e.g. v1.0.0)
./build_and_load.sh claude-agy v1.0.0

# Preview steps without building
./build_and_load.sh claude-agy --dry-run
```

---

## Running a Sandbox Instance

Once the template is loaded, launch a container session. Note that you must start the container before you can apply project-specific network policies to it:

```bash
sbx run --template claude-code-agy:latest --name sandboxed-claude-agy claude
```
