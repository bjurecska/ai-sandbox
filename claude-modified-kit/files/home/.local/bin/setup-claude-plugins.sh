#!/usr/bin/env bash
# Install the ai-plugins marketplace and the agy-delegate plugin.
#
# Runs as a setup.startup command on every sandbox start, chained after
# sync-claude-config.sh, so it must stay idempotent. The order is not
# cosmetic: that sync rsyncs the dotfiles repo over ~/.claude, and
# ~/.claude/settings.json is where enabledPlugins and extraKnownMarketplaces
# live — installing before it lands means installing into a file that is
# about to be replaced.
set -euo pipefail

MARKETPLACE_URL="https://github.com/bjurecska/ai-plugins.git"
MARKETPLACE_NAME="ai-plugins"
PLUGIN_NAME=""
PLUGIN_ID="${PLUGIN_NAME}@${MARKETPLACE_NAME}"

# Startup output is captured nowhere by sbx — keep a log so boot-time
# failures can be diagnosed after the fact.
LOG_FILE="${HOME}/.cache/setup-claude-plugins.log"
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== run $(date -u +%FT%TZ) ==="

# Barrier, not a lock we keep: sbx can fire one startup entry several times
# concurrently, and the losing instances' sync-claude-config.sh exits at once
# on its non-blocking lock. Without this wait those instances would race their
# plugin install ahead of the winner's still-running rsync. Take the sync's
# lock (blocking), then drop it immediately — holding it through the install
# would stall a concurrent sync for no reason.
exec 8>"${HOME}/.cache/sync-claude-config.flock"
if flock -w 300 8; then
  exec 8>&-
else
  echo "setup-claude-plugins: timed out waiting for the config sync; continuing" >&2
fi

# Serialize the install itself: losers exit cleanly, the winner installs.
exec 9>"${HOME}/.cache/setup-claude-plugins.flock"
if ! flock -n 9; then
  echo "setup-claude-plugins: another instance holds the lock; exiting"
  exit 0
fi

# Prepend only when absent: a duplicate entry makes the plugin installer's
# PATH-shadow scan report the same directory twice as competing copies.
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac

if ! command -v claude >/dev/null 2>&1; then
  echo "setup-claude-plugins: claude not found on PATH" >&2
  exit 1
fi

# Re-running these is the steady state, not the exception: a known marketplace
# and an installed plugin are both reported as already present. '|| true' keeps
# a non-zero exit from any of them — 'enable' below does fail this way once the
# plugin is enabled — from killing the startup command; the explicit check
# after them is what decides whether the install actually succeeded.
#
# The git URL is deliberate: the 'bjurecska/ai-plugins' shorthand resolves via
# api.github.com, and a directory source would only ever resolve in a sandbox
# whose workspace happens to be the plugin repo itself.
echo "setup-claude-plugins: registering marketplace ${MARKETPLACE_NAME}"
claude plugin marketplace add "${MARKETPLACE_URL}" --scope user || true
if [ -z "${PLUGIN_NAME}" ]; then
  echo "setup-claude-plugins: no PLUGIN_NAME set; marketplace registered, skipping plugin install"
  exit 0
fi

echo "setup-claude-plugins: installing ${PLUGIN_ID}"
claude plugin install "${PLUGIN_ID}" --scope user || true

# Load-bearing, not belt-and-braces: once the rsync has replaced settings.json,
# enabledPlugins no longer lists the plugin, but installed_plugins.json still
# does — so 'install' above sees it as present and does not re-enable it.
claude plugin enable "${PLUGIN_ID}" || true

if ! claude plugin list --json 2>/dev/null \
     | jq -e --arg id "${PLUGIN_ID}" 'map(select(.id == $id and .enabled)) | length > 0' \
       >/dev/null; then
  echo "setup-claude-plugins: ${PLUGIN_ID} is not installed and enabled — check" \
       "the github.com network allowlist in spec.yaml" >&2
  exit 1
fi

INSTALL_PATH="$(claude plugin list --json 2>/dev/null \
  | jq -r --arg id "${PLUGIN_ID}" 'map(select(.id == $id)) | .[0].installPath // empty')"

if [ -z "${INSTALL_PATH}" ]; then
  echo "setup-claude-plugins: ${PLUGIN_ID} reports no installPath" >&2
  exit 1
fi
echo "setup-claude-plugins: installed at ${INSTALL_PATH}"

# Claude Code creates everything under ~/.claude group-writable (775/664) even
# though the umask here is 022, and the plugin's installer refuses to pin a
# launcher through a group- or other-writable path — anyone with write access
# there could swap the script the launcher execs. Drop the group/other write
# bits on this plugin so that check passes. Re-applied every start because a
# reinstall recreates the files with the original modes.
chmod -R go-w "${INSTALL_PATH}"

