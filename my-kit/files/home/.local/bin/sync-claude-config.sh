#!/usr/bin/env bash
# Sync ~/.claude from the claude-home dotfiles repo.
#
# Runs as a setup.startup command on every sandbox start, so it must stay
# idempotent. No credential is handled in this script: the sandbox proxy
# injects the gitlab-config-repo deploy token as HTTP Basic auth on
# requests to gitlab.com (see spec.yaml).
set -euo pipefail

# The dotfiles repo to sync from — no default; set it via the kit's
# environment.variables (see README). A repo on a different host than the
# inject domain in spec.yaml also needs that domain and the network
# allowlist updated to match.
if [ -z "${CLAUDE_CONFIG_REPO_URL:-}" ]; then
  echo "sync-claude-config: CLAUDE_CONFIG_REPO_URL is not set — set it in" \
       "the kit's environment.variables (see my-kit/README.md)" >&2
  exit 1
fi
REPO_URL="${CLAUDE_CONFIG_REPO_URL}"
CACHE_DIR="${HOME}/.cache/claude-config-src"
TARGET_DIR="${HOME}/.claude"

# Files the sandbox owns that the repo must never clobber.
# .credentials.json is where Claude Code keeps its auth state (and where
# the sandbox's OAuth credentialFile sentinels land). Extend this list if
# `sbx exec` shows more auth files under ~/.claude after a real /login.
RSYNC_EXCLUDES=(
  --exclude '.git/'
  --exclude '.credentials.json'
)

export GIT_TERMINAL_PROMPT=0

if [ -d "${CACHE_DIR}/.git" ]; then
  if ! git -C "${CACHE_DIR}" pull --ff-only --quiet; then
    echo "sync-claude-config: pull failed; syncing from the cached copy" >&2
  fi
else
  rm -rf "${CACHE_DIR}"
  mkdir -p "$(dirname "${CACHE_DIR}")"
  if ! git clone --quiet --depth 1 "${REPO_URL}" "${CACHE_DIR}"; then
    echo "sync-claude-config: clone failed — is the gitlab-config-repo" \
         "secret set on the host? (sbx secret set gitlab-config-repo)" >&2
    exit 1
  fi
fi

mkdir -p "${TARGET_DIR}"
# No --delete: the repo is an overlay. Runtime state under ~/.claude
# (projects/, todos/, statsig/, …) must survive every sync.
rsync -a "${RSYNC_EXCLUDES[@]}" "${CACHE_DIR}/" "${TARGET_DIR}/"
echo "sync-claude-config: synced ${TARGET_DIR} from ${REPO_URL}"
