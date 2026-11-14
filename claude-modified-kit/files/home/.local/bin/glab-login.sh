#!/usr/bin/env bash
# Authenticate the glab CLI against gitlab.com.
#
# Runs as a setup.startup command on every sandbox start, so it must stay
# idempotent. GITLAB_CLI_TOKEN holds a proxy-managed sentinel, not the
# real token: the proxy rewrites the PRIVATE-TOKEN header on requests to
# gitlab.com (see spec.yaml), so the sentinel is what glab stores and
# sends. Works unchanged for a PAT, project, or group access token.
set -euo pipefail

# Overridable; glab itself honors GITLAB_HOST too, so one override points
# both this login and later glab calls at the same instance. A host other
# than gitlab.com also needs the inject domain and network allowlist in
# spec.yaml updated to match.
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"

if ! command -v glab >/dev/null 2>&1; then
  echo "glab-login: glab not found on PATH" >&2
  exit 1
fi

if [ -z "${GITLAB_CLI_TOKEN:-}" ]; then
  echo "glab-login: GITLAB_CLI_TOKEN is not set — is the gitlab-cli" \
       "secret set on the host? (sbx secret set gitlab-cli)" >&2
  exit 1
fi

if glab auth status --hostname "${GITLAB_HOST}" >/dev/null 2>&1; then
  echo "glab-login: already authenticated to ${GITLAB_HOST}"
  exit 0
fi

printf '%s\n' "${GITLAB_CLI_TOKEN}" \
  | glab auth login --hostname "${GITLAB_HOST}" --stdin

# Re-check so a bad token fails the startup command loudly instead of
# leaving a half-configured glab behind.
glab auth status --hostname "${GITLAB_HOST}" >/dev/null
echo "glab-login: authenticated to ${GITLAB_HOST}"
