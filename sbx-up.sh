#!/usr/bin/env bash
# =============================================================================
# Bring up a kitted sandbox: MCP servers attached, network policies applied
# =============================================================================
# Composes the steps a working sandbox needs into one command:
#
#   1. Preflight    — the MCP servers named by --mcp must already be registered
#                     on the host (sbx mcp add) and, where they use OAuth,
#                     authorized (sbx mcp auth).
#   2. sbx create   — with --kit ./my-kit/ and --static-mcp. Creating rather
#                     than running, so the later steps are reachable: sbx run
#                     opens an interactive session and does not return.
#   3. apply_policy.sh — the sandbox-specific network allowlist.
#   4. sbx run      — attach, unless --no-attach.
#
# Why the MCP servers are attached from the host rather than registered inside
# the sandbox: 'sbx mcp add --command' runs the server binary on the HOST. The
# sandbox image has no qmd, no op and no 1password-mcp, and qmd's index covers
# host paths the sandbox cannot see, so a sandbox-local 'claude mcp add' would
# register servers that can never start. The gateway is the only route that
# works. See my-kit/README.md.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep in sync with the run command documented in my-kit/README.md.
DEFAULT_TEMPLATE="ghcr.io/bjurecska/ai-sandbox/claude-agy:1.3"
DEFAULT_NAME="sandboxed-claude-agy"
# 1password is deliberately absent: its MCP server publishes resources under the
# scheme '1password://', which RFC 3986 forbids (a scheme must start with a
# letter), and the sbx gateway returns 500 when it parses them. Renaming the
# registration does not help — the URI comes from the server, not from sbx.
DEFAULT_MCP="GitLab,qmd"
DEFAULT_POLICY_PROJECT="claude-agy"

TEMPLATE="${DEFAULT_TEMPLATE}"
NAME="${DEFAULT_NAME}"
MCP="${DEFAULT_MCP}"
POLICY_PROJECT="${DEFAULT_POLICY_PROJECT}"
NO_POLICY=false
NO_ATTACH=false
DRY_RUN=false
WORKSPACES=()

show_help() {
    cat << EOF
Usage: $(basename "$0") [options] [workspace...]

Creates a sandbox from the claude-agy template with the my-kit mixin, attaches
the host's MCP servers to it, applies its network policies, and opens a session.

Arguments:
  workspace...           Host paths to mount (default: the current directory).
                         Append ":ro" to mount one read-only.

Options:
  -n, --name <name>      Sandbox name (default: ${DEFAULT_NAME})
  -t, --template <ref>   Container image to use (default: ${DEFAULT_TEMPLATE})
  -m, --mcp <list>       Comma-separated MCP server names to attach as the
                         sandbox's static set (default: ${DEFAULT_MCP}).
                         Pass an empty string to attach none.
  -p, --policy <dir>     Project dir holding sbx-policy.yaml (default: ${DEFAULT_POLICY_PROJECT})
      --no-policy        Skip the apply_policy.sh step
      --no-attach        Create and configure, but do not open a session
  -d, --dry-run          Print the commands without executing them
  -h, --help             Display this help message

Examples:
  # Bring up the default sandbox on the current directory
  ./sbx-up.sh

  # A differently named sandbox on a specific workspace
  ./sbx-up.sh --name my-sandbox ~/git/my-project

  # Prepare it for later, without attaching
  ./sbx-up.sh --name my-sandbox --no-attach

  # Preview
  ./sbx-up.sh --dry-run

Notes:
  --static-mcp is fixed when the sandbox is CREATED and cannot be changed
  afterwards. Re-running this script against an existing sandbox skips creation,
  so it will NOT pick up a changed --mcp. To add a server to a sandbox that
  already exists:  sbx mcp load <name> --sandbox <sandbox>
  To change the set, recreate the sandbox.

  apply_policy.sh performs a TWO-WAY sync: it revokes any active network rule
  that is not in the YAML manifest. Ad-hoc 'sbx policy allow' additions do not
  survive it — put the domain in the manifest (or the kit spec) instead.
EOF
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Missing value for --name" >&2
                exit 1
            fi
            NAME="$2"
            shift 2
            ;;
        -t|--template)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Missing value for --template" >&2
                exit 1
            fi
            TEMPLATE="$2"
            shift 2
            ;;
        -m|--mcp)
            if [[ $# -lt 2 ]]; then
                echo "Error: Missing value for --mcp" >&2
                exit 1
            fi
            MCP="$2"
            shift 2
            ;;
        -p|--policy)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Missing value for --policy" >&2
                exit 1
            fi
            POLICY_PROJECT="$2"
            shift 2
            ;;
        --no-policy)
            NO_POLICY=true
            shift
            ;;
        --no-attach)
            NO_ATTACH=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            show_help
            exit 1
            ;;
        *)
            WORKSPACES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#WORKSPACES[@]} -eq 0 ]]; then
    WORKSPACES=(".")
fi

if ! command -v sbx >/dev/null 2>&1; then
    echo "Error: 'sbx' binary not found on PATH." >&2
    exit 1
fi

KIT_DIR="${SCRIPT_DIR}/my-kit"
if [[ ! -f "${KIT_DIR}/spec.yaml" ]]; then
    echo "Error: ${KIT_DIR}/spec.yaml not found." >&2
    echo "       It is gitignored; create it from the template:" >&2
    echo "         cp my-kit/spec.yaml.template my-kit/spec.yaml" >&2
    echo "       then fill in CLAUDE_CONFIG_REPO_URL (see my-kit/README.md)." >&2
    exit 1
fi

# Split --mcp into an array, ignoring empty fields so that a trailing comma or
# an empty --mcp is not treated as a server named "".
# The trailing newline from printf is load-bearing: without it 'read' fails on
# the final field and silently drops the last server from the set.
MCP_SERVERS=()
if [[ -n "${MCP}" ]]; then
    while IFS= read -r srv; do
        [[ -n "${srv}" ]] && MCP_SERVERS+=("${srv}")
    done < <(printf '%s\n' "${MCP}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
fi

# -----------------------------------------------------------------------------
# Step 1/4: Preflight the MCP registrations
# -----------------------------------------------------------------------------
echo "================================================================="
echo " Step 1/4: Checking MCP server registrations"
echo "================================================================="

if [[ ${#MCP_SERVERS[@]} -eq 0 ]]; then
    echo "==> No MCP servers requested; skipping."
else
    REGISTERED="$(sbx mcp ls 2>/dev/null | awk 'NR > 1 { print $1 }' || true)"
    MISSING=()
    for srv in "${MCP_SERVERS[@]}"; do
        if ! printf '%s\n' "${REGISTERED}" | grep -q -x -F "${srv}"; then
            MISSING+=("${srv}")
        fi
    done

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "Error: these MCP servers are not registered on this host: ${MISSING[*]}" >&2
        echo "" >&2
        echo "Register them before creating the sandbox, e.g.:" >&2
        echo "  sbx mcp add <name> --url https://host/mcp        # remote" >&2
        echo "  sbx mcp add <name> --command /path/to/binary     # local stdio (runs on the HOST)" >&2
        echo "" >&2
        echo "Currently registered:" >&2
        sbx mcp ls >&2 || true
        exit 1
    fi
    echo "==> Registered: ${MCP_SERVERS[*]}"

    # Surface unauthorized OAuth servers rather than creating a sandbox whose
    # tools 401 on first use. The auth flow itself is interactive, so it is
    # reported here, never run from here.
    AUTH_STATUS="$(sbx mcp auth status --all 2>/dev/null || true)"
    if [[ -n "${AUTH_STATUS}" ]]; then
        for srv in "${MCP_SERVERS[@]}"; do
            if printf '%s\n' "${AUTH_STATUS}" | grep -q -- "\"${srv}\"" &&
               ! printf '%s\n' "${AUTH_STATUS}" | grep -q -- "\"${srv}\" authorized"; then
                echo "==> Warning: MCP server '${srv}' does not report as authorized."
                echo "    Authorize it with:  sbx mcp auth ${srv}"
            fi
        done
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Step 2/4: Create the sandbox
# -----------------------------------------------------------------------------
echo "================================================================="
echo " Step 2/4: Creating sandbox '${NAME}'"
echo "================================================================="

SANDBOX_EXISTS=false
if sbx ls 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -q -x -F "${NAME}"; then
    SANDBOX_EXISTS=true
fi

if [[ "${SANDBOX_EXISTS}" == true ]]; then
    echo "==> Sandbox '${NAME}' already exists; skipping creation."
    if [[ ${#MCP_SERVERS[@]} -gt 0 ]]; then
        echo "    Its static MCP set was fixed at creation and is NOT updated here."
        echo "    To attach a server to it now:  sbx mcp load <name> --sandbox ${NAME}"
    fi
else
    CREATE_CMD=(sbx create --template "${TEMPLATE}" --kit "${KIT_DIR}/" --name "${NAME}")
    if [[ ${#MCP_SERVERS[@]} -gt 0 ]]; then
        CREATE_CMD+=(--static-mcp "${MCP}")
    fi
    CREATE_CMD+=(claude "${WORKSPACES[@]}")

    if [[ "${DRY_RUN}" == true ]]; then
        printf '[DRY-RUN]'
        printf ' %q' "${CREATE_CMD[@]}"
        printf '\n'
    else
        "${CREATE_CMD[@]}"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Step 3/4: Network policies
# -----------------------------------------------------------------------------
if [[ "${NO_POLICY}" == true ]]; then
    echo "==> Skipping network policy sync (--no-policy)."
else
    echo "================================================================="
    echo " Step 3/4: Applying network policies"
    echo "================================================================="

    POLICY_CMD=("${SCRIPT_DIR}/apply_policy.sh" "${POLICY_PROJECT}" --sandbox "${NAME}")
    if [[ "${DRY_RUN}" == true ]]; then
        POLICY_CMD+=(--dry-run)
    fi
    "${POLICY_CMD[@]}"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 4/4: Attach
# -----------------------------------------------------------------------------
echo "================================================================="
echo " Step 4/4: Attaching to '${NAME}'"
echo "================================================================="

ATTACH_CMD=(sbx run --name "${NAME}")

if [[ "${NO_ATTACH}" == true ]]; then
    echo "==> Not attaching (--no-attach). Open a session with:"
    printf '     '
    printf '%q ' "${ATTACH_CMD[@]}"
    printf '\n'
    exit 0
fi

if [[ "${DRY_RUN}" == true ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "${ATTACH_CMD[@]}"
    printf '\n'
    exit 0
fi

exec "${ATTACH_CMD[@]}"
