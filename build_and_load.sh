#!/usr/bin/env bash
# =============================================================================
# Build and Load Docker Sandbox Template
# =============================================================================
# Builds a container image for a specified project folder, saves the image to
# a tarball, and loads it into sbx template storage.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << EOF
Usage: $(basename "$0") <project_dir> [tag] [options]

Builds a sandbox image for <project_dir>, saves the image tarball,
and loads the template into sbx.

Arguments:
  project_dir            Path to project subfolder (e.g. claude-agy)
  tag                    Image tag name (default: latest)

Options:
  --dry-run              Preview actions without executing build or load
  -h, --help             Display this help message

Examples:
  # Build and load 'claude-agy' project with tag 'latest'
  ./build_and_load.sh claude-agy

  # Build with custom tag v1.0.0
  ./build_and_load.sh claude-agy v1.0.0

  # Preview steps with --dry-run
  ./build_and_load.sh claude-agy --dry-run
EOF
}

if [[ $# -lt 1 ]]; then
    echo "Error: Missing required argument <project_dir>" >&2
    show_help
    exit 1
fi

PROJECT_DIR=""
TAG="latest"
DRY_RUN=false
CI_MODE=false
CUSTOM_IMAGE_NAME=""

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        --image-name)
            CUSTOM_IMAGE_NAME="$2"
            shift 2
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
            if [[ -z "${PROJECT_DIR}" ]]; then
                PROJECT_DIR="$1"
            elif [[ "${TAG}" == "latest" ]]; then
                TAG="$1"
            else
                echo "Error: Unexpected argument '$1'" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

TARGET_PATH="${SCRIPT_DIR}/${PROJECT_DIR%/}"

if [[ ! -d "${TARGET_PATH}" ]]; then
    echo "Error: Project directory '${TARGET_PATH}' does not exist!" >&2
    exit 1
fi

if [[ ! -f "${TARGET_PATH}/Dockerfile" ]]; then
    echo "Error: No Dockerfile found in '${TARGET_PATH}'!" >&2
    exit 1
fi

PROJECT_NAME="$(basename "${TARGET_PATH}")"
if [[ -n "${CUSTOM_IMAGE_NAME}" ]]; then
    IMAGE_NAME="${CUSTOM_IMAGE_NAME}"
else
    IMAGE_NAME="${PROJECT_NAME}:${TAG}"
fi
TAR_FILE="${TARGET_PATH}/${PROJECT_NAME}-${TAG}.tar"

echo "================================================================="
echo " Building Project: ${PROJECT_NAME}"
echo " Target Tag:       ${TAG}"
echo " Image Name:       ${IMAGE_NAME}"
echo " Tarball Path:     ${TAR_FILE}"
echo "================================================================="

# Step 1: Build Image
echo ""
echo "==> Step 1: Building container image '${IMAGE_NAME}'..."
if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] cd ${TARGET_PATH}"
    echo "[DRY-RUN] sudo buildah --storage-driver vfs build --isolation chroot -t ${IMAGE_NAME} -f ./Dockerfile ."
else
    cd "${TARGET_PATH}"
    if command -v buildah >/dev/null 2>&1; then
        sudo buildah --storage-driver vfs build --isolation chroot -t "${IMAGE_NAME}" -f ./Dockerfile .
    else
        docker build -t "${IMAGE_NAME}" .
    fi
fi

if [[ "${CI_MODE}" == true ]]; then
    echo ""
    echo "    [Notice] --ci flag provided. Skipping image save and sbx template load."
    exit 0
fi

# Step 2: Save Image Tarball
echo ""
echo "==> Step 2: Saving image '${IMAGE_NAME}' to '${TAR_FILE}'..."
if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] sudo buildah --storage-driver vfs push ${IMAGE_NAME} oci-archive:${TAR_FILE}"
else
    if command -v buildah >/dev/null 2>&1; then
        sudo buildah --storage-driver vfs push "${IMAGE_NAME}" "oci-archive:${TAR_FILE}"
    else
        docker image save "${IMAGE_NAME}" -o "${TAR_FILE}"
    fi
fi

# Step 3: Load Template into SBX
echo ""
echo "==> Step 3: Loading template into sbx..."
if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] sbx template load ${TAR_FILE}"
else
    if command -v sbx >/dev/null 2>&1; then
        sbx template load "${TAR_FILE}"
        echo "==> Successfully built and loaded '${TAR_FILE}' into sbx!"
    else
        echo "    [Notice] 'sbx' CLI not found on PATH. Image tarball saved to:"
        echo "    ${TAR_FILE}"
    fi
fi
