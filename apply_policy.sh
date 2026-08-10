#!/usr/bin/env bash
# =============================================================================
# Apply SBX Network Policies
# =============================================================================
# Reads domains from sbx-policy.yaml and synchronizes network allowlist rules.
#
# Modes:
# - Global Mode (--global): Synchronizes root global policies across sbx using
#   sbx-policy-global.yaml. Adds missing rules & revokes unmanifested global rules.
# - Sandbox Mode (--sandbox <name>): Synchronizes rules for a specific sandbox using
#   <project_dir>/sbx-policy.yaml. Automatically syncs global policies first
#   (unless --skip-global is specified).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_POLICY_FILE="${SCRIPT_DIR}/sbx-policy-global.yaml"
TARGET_DIR=""
POLICY_FILE=""
MODE="global"
EXPLICIT_GLOBAL=false
SANDBOX_NAME=""
SKIP_GLOBAL=false
DRY_RUN=false
IS_CASCADE=false

show_help() {
    cat << EOF
Usage: $(basename "$0") [project_dir] [options]

Applies network allowlist policies to sbx (Docker Sandbox) based on sbx-policy.yaml.

Arguments:
  project_dir            Path to project subfolder (e.g. claude-agy).
                         If omitted, defaults to root sbx-policy-global.yaml.

Options:
  -g, --global           Synchronize network policies globally across all sandboxes (default)
  -s, --sandbox <name>   Synchronize network policies for a specific named sandbox
  --skip-global          Skip automatic synchronization of global baseline policies
  -f, --file <path>      Explicit path to policy YAML file
  -d, --dry-run          Preview sbx allow/revoke commands without executing them
  -h, --help             Display this help message

Examples:
  # Synchronize global baseline policies
  ./apply_policy.sh --global

  # Synchronize sandbox policies (automatically syncs global rules first)
  ./apply_policy.sh claude-agy --sandbox my-sandbox

  # Synchronize sandbox policies without updating global rules
  ./apply_policy.sh claude-agy --sandbox my-sandbox --skip-global

  # Preview actions with dry-run
  ./apply_policy.sh claude-agy --sandbox my-sandbox --dry-run
EOF
}

# Helper function to extract domains from a YAML policy file using python3
extract_domains() {
    local pfile="$1"
    python3 -c '
import sys, re
try:
    with open(sys.argv[1], "r") as f:
        for line in f:
            m = re.search(r"^\s*-\s*domain:\s*[\"\x27\s]*(.*?)[\"\x27\s]*$", line)
            if m and m.group(1):
                val = m.group(1).strip("\" \x27")
                if val:
                    print(val)
except Exception:
    pass
' "${pfile}" 2>/dev/null || true
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--global)
            MODE="global"
            EXPLICIT_GLOBAL=true
            shift
            ;;
        -s|--sandbox)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Missing sandbox name for --sandbox" >&2
                exit 1
            fi
            MODE="sandbox"
            SANDBOX_NAME="$2"
            shift 2
            ;;
        --skip-global)
            SKIP_GLOBAL=true
            shift
            ;;
        --cascade-internal)
            IS_CASCADE=true
            shift
            ;;
        -f|--file)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Missing file path for --file" >&2
                exit 1
            fi
            POLICY_FILE="$2"
            shift 2
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
            if [[ -z "${TARGET_DIR}" ]]; then
                TARGET_DIR="$1"
            else
                echo "Error: Unexpected argument '$1'" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# If a target project directory is specified and --global was not explicitly passed,
# default to sandbox mode targeting that project name.
if [[ -n "${TARGET_DIR}" && "${EXPLICIT_GLOBAL}" == false ]]; then
    MODE="sandbox"
    if [[ -z "${SANDBOX_NAME}" ]]; then
        SANDBOX_NAME="$(basename "${TARGET_DIR%/}")"
    fi
fi

# If sandbox mode is active and TARGET_DIR is not set, infer TARGET_DIR from SANDBOX_NAME or existing project dirs
if [[ "${MODE}" == "sandbox" && -z "${TARGET_DIR}" && -z "${POLICY_FILE}" && -n "${SANDBOX_NAME}" ]]; then
    if [[ -d "${SCRIPT_DIR}/${SANDBOX_NAME}" || -d "${SANDBOX_NAME}" ]]; then
        TARGET_DIR="${SANDBOX_NAME}"
    else
        # Search for project subdirectories containing sbx-policy.yaml
        CANDIDATES=()
        for d in "${SCRIPT_DIR}"/*/; do
            if [[ -d "$d" && -f "${d}sbx-policy.yaml" ]]; then
                CANDIDATES+=("$(basename "$d")")
            fi
        done
        
        if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
            TARGET_DIR="${CANDIDATES[0]}"
            echo "==> Notice: Directory '${SANDBOX_NAME}' not found. Using policy manifest from project '${TARGET_DIR}'."
        elif [[ ${#CANDIDATES[@]} -gt 1 ]]; then
            echo "Error: Directory '${SANDBOX_NAME}' not found and multiple project policy manifests exist (${CANDIDATES[*]})." >&2
            echo "Please specify the source project directory, e.g.:" >&2
            echo "  $0 ${CANDIDATES[0]} --sandbox ${SANDBOX_NAME}" >&2
            exit 1
        fi
    fi
fi

# Step 0: In Sandbox mode, automatically sync Global rules first (unless --skip-global set)
if [[ "${MODE}" == "sandbox" && "${SKIP_GLOBAL}" == false && "${IS_CASCADE}" == false ]]; then
    if [[ -f "${GLOBAL_POLICY_FILE}" ]]; then
        echo "================================================================="
        echo " Step 1/2: Synchronizing Global Baseline Policies"
        echo "================================================================="
        if [[ "${DRY_RUN}" == true ]]; then
            "${BASH_SOURCE[0]}" --global --cascade-internal --dry-run
        else
            "${BASH_SOURCE[0]}" --global --cascade-internal
        fi
        echo ""
        echo "================================================================="
        echo " Step 2/2: Synchronizing Sandbox-Specific Policies ('${SANDBOX_NAME}')"
        echo "================================================================="
    fi
fi

# Resolve policy file location for current run
if [[ -n "${POLICY_FILE}" ]]; then
    RESOLVED_POLICY="${POLICY_FILE}"
elif [[ -n "${TARGET_DIR}" ]]; then
    if [[ "${TARGET_DIR}" = /* ]]; then
        RESOLVED_DIR="${TARGET_DIR%/}"
    else
        RESOLVED_DIR="${SCRIPT_DIR}/${TARGET_DIR%/}"
    fi
    RESOLVED_POLICY="${RESOLVED_DIR}/sbx-policy.yaml"
    if [[ ! -f "${RESOLVED_POLICY}" && -f "${RESOLVED_DIR}/sbx-policy-global.yaml" ]]; then
        RESOLVED_POLICY="${RESOLVED_DIR}/sbx-policy-global.yaml"
    fi
else
    RESOLVED_POLICY="${GLOBAL_POLICY_FILE}"
    if [[ ! -f "${RESOLVED_POLICY}" && -f "${SCRIPT_DIR}/sbx-policy.yaml" ]]; then
        RESOLVED_POLICY="${SCRIPT_DIR}/sbx-policy.yaml"
    fi
fi

if [[ ! -f "${RESOLVED_POLICY}" ]]; then
    echo "Error: Policy file '${RESOLVED_POLICY}' not found!" >&2
    exit 1
fi

echo "==> Loading SBX network policies from: ${RESOLVED_POLICY}"

# Extract domain list
DOMAINS=$(extract_domains "${RESOLVED_POLICY}")

if [[ -z "${DOMAINS}" ]]; then
    echo "==> Notice: No network policy rules defined in ${RESOLVED_POLICY}."
    exit 0
fi

# Build sbx command prefixes and list command
ALLOW_CMD_PREFIX="sbx policy allow network"
REVOKE_CMD_PREFIX="sbx policy revoke network"
LS_CMD="sbx policy ls"

if [[ "${MODE}" == "sandbox" ]]; then
    ALLOW_CMD_PREFIX="sbx policy allow network --sandbox ${SANDBOX_NAME}"
    REVOKE_CMD_PREFIX="sbx policy revoke network --sandbox ${SANDBOX_NAME}"
    LS_CMD="sbx policy ls"
    echo "==> Synchronizing policies for sandbox '${SANDBOX_NAME}'..."
else
    echo "==> Synchronizing global policies across all sandboxes..."
fi

echo ""

# Convert manifest domains into array
MANIFEST_DOMAINS=()
while IFS= read -r domain; do
    [[ -n "${domain}" ]] && MANIFEST_DOMAINS+=("${domain}")
done <<< "${DOMAINS}"

# Step 1: Ensure/Allow all domains from manifest
for domain in "${MANIFEST_DOMAINS[@]}"; do
    FULL_CMD="${ALLOW_CMD_PREFIX} \"${domain}\""
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] ${FULL_CMD}"
    else
        echo "--> [ALLOW] Allowing network access to: ${domain}"
        if command -v sbx >/dev/null 2>&1; then
            eval "${FULL_CMD}"
        else
            echo "    [Notice] 'sbx' binary not found on PATH. Command to execute:"
            echo "    ${FULL_CMD}"
        fi
    fi
done

# Step 2: Revoke any active network rules not in manifest
echo ""
if [[ "${MODE}" == "sandbox" ]]; then
    echo "==> Checking for unmanifested network rules to revoke on sandbox '${SANDBOX_NAME}'..."
else
    echo "==> Checking for unmanifested global network rules to revoke..."
fi

if command -v sbx >/dev/null 2>&1; then
    # Parse active network rules from sbx policy ls
    CURRENT_RULES=$(${LS_CMD} 2>/dev/null | grep -E '\snetwork\s+allow\s+' | awk '{print $NF}' || true)
    
    if [[ -n "${CURRENT_RULES}" ]]; then
        while IFS= read -r active_domain; do
            [[ -z "${active_domain}" ]] && continue
            
            # Check if active_domain is in MANIFEST_DOMAINS
            IN_MANIFEST=false
            for m_domain in "${MANIFEST_DOMAINS[@]}"; do
                if [[ "${m_domain}" == "${active_domain}" ]]; then
                    IN_MANIFEST=true
                    break
                fi
            done
            
            if [[ "${IN_MANIFEST}" == false ]]; then
                REVOKE_CMD="${REVOKE_CMD_PREFIX} \"${active_domain}\""
                if [[ "${DRY_RUN}" == true ]]; then
                    echo "[DRY-RUN] ${REVOKE_CMD}"
                else
                    echo "--> [REVOKE] Removing unmanifested rule for: ${active_domain}"
                    eval "${REVOKE_CMD}"
                fi
            fi
        done <<< "${CURRENT_RULES}"
    fi
else
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] (If active network rules exist that are not in manifest, run: ${REVOKE_CMD_PREFIX} \"<unmanifested_domain>\")"
    fi
fi

echo ""
if [[ "${DRY_RUN}" == true ]]; then
    echo "==> Policy dry run complete. No policies were modified."
else
    echo "==> Network policies synchronized successfully!"
    if command -v sbx >/dev/null 2>&1; then
        echo "==> Current SBX Policies:"
        eval "${LS_CMD}" || true
    fi
fi
