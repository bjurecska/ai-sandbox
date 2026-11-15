#!/usr/bin/env bash
# Sync ~/.claude from the claude-home dotfiles repo.
#
# Runs as a setup.startup command on every sandbox start, so it must stay
# idempotent. Auth: see the GITLAB_CONFIG_REPO_TOKEN block below — the real
# deploy token never enters the sandbox.
set -euo pipefail

# Startup output is captured nowhere by sbx — keep a log so boot-time
# failures can be diagnosed after the fact.
LOG_FILE="${HOME}/.cache/sync-claude-config.log"
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== run $(date -u +%FT%TZ) ==="

# sbx can fire this startup entry several times concurrently on one
# start (observed: four instances in the same second, shredding each
# other's clone). Serialize: losers exit cleanly, the winner syncs.
exec 9>"${HOME}/.cache/sync-claude-config.flock"
if ! flock -n 9; then
  echo "sync-claude-config: another instance holds the lock; exiting"
  exit 0
fi

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

# GITLAB_CONFIG_REPO_TOKEN holds a unique placeholder set by the host's
# custom secret (sbx secret set-custom --host gitlab.com --env ...; the
# stored value is base64 of "<deploy-token-user>:<token>"). git sends
# the placeholder verbatim in the Authorization header and the proxy
# substitutes the real value in flight — the token never enters the
# sandbox. The proxy only rewrites values it can see in a header, which
# is why git must send this itself rather than rely on injection.
if [ -z "${GITLAB_CONFIG_REPO_TOKEN:-}" ]; then
  echo "sync-claude-config: GITLAB_CONFIG_REPO_TOKEN is not set — create the" \
       "custom secret on the host (see my-kit/README.md)" >&2
  exit 1
fi
AUTH_HEADER="Authorization: Basic ${GITLAB_CONFIG_REPO_TOKEN}"
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
  if ! git -C "${CACHE_DIR}" \
       pull --ff-only --quiet; then
    echo "sync-claude-config: pull failed; syncing from the cached copy" >&2
  fi
else
  rm -rf "${CACHE_DIR}"
  mkdir -p "$(dirname "${CACHE_DIR}")"
  # The proxy/network path may not be up in the first seconds of sandbox
  # startup (observed: clone fails at boot, succeeds moments later while
  # the later glab-login startup step already works) — retry before
  # giving up.
  cloned=false
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if git \
         clone --quiet --depth 1 "${REPO_URL}" "${CACHE_DIR}"; then
      cloned=true
      break
    fi
    echo "sync-claude-config: clone attempt ${attempt} failed; retrying in 3s" >&2
    rm -rf "${CACHE_DIR}"
    sleep 3
  done
  if [ "${cloned}" != true ]; then
    echo "sync-claude-config: clone failed after 10 attempts — check the" \
         "custom secret (sbx secret set-custom ..., see my-kit/README.md)" >&2
    exit 1
  fi
fi

mkdir -p "${TARGET_DIR}"
# No --delete: the repo is an overlay. Runtime state under ~/.claude
# (projects/, todos/, statsig/, …) must survive every sync.
rsync -a "${RSYNC_EXCLUDES[@]}" "${CACHE_DIR}/" "${TARGET_DIR}/"
echo "sync-claude-config: synced ${TARGET_DIR} from ${REPO_URL}"
