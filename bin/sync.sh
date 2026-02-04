#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/json.sh"
source "${ROOT_DIR}/lib/fs.sh"
source "${ROOT_DIR}/lib/net.sh"

STACK=""
WORKFLOW_KEY=""
OPTIONAL_PATHS=()
OPTIONAL_SET=()

usage() {
  cat <<USAGE
Usage: bin/sync.sh --stack <wan|qwen> --workflow <workflow_key> [--optional <path> ...]

Env overrides:
  ARTIFACT_HOST  Override config artifact_host
  COMFY_ROOT     Force comfy root path
  MAX_PARALLEL   Optional; 0=unlimited (unused for now)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)
      STACK="$2"; shift 2;;
    --workflow)
      WORKFLOW_KEY="$2"; shift 2;;
    --optional)
      OPTIONAL_PATHS+=("$2"); shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 1;;
  esac
done

if [[ -z "$STACK" || -z "$WORKFLOW_KEY" ]]; then
  usage
  exit 1
fi

if [[ -z "$STACK" ]]; then
  usage
  exit 1
fi

CONFIG_FILE="${ROOT_DIR}/config/config.json"
MANIFEST_FILE="$(fetch_manifest "$CONFIG_FILE")"

COMFY_ROOT="$(detect_comfy_root "$CONFIG_FILE")"
WORKFLOWS_REL="$(json_get "$CONFIG_FILE" '.workflows_dir_rel')"
ACTIVE_REL="$(json_get "$CONFIG_FILE" '.active_workflow_dir_rel')"
MODELS_REL="$(json_get "$CONFIG_FILE" '.models_dir_rel')"

ensure_workflow_dirs "$COMFY_ROOT" "$WORKFLOWS_REL" "$ACTIVE_REL"

ARTIFACT_HOST="${ARTIFACT_HOST:-}"
STACKS_BASE_PATH="$(json_get "$CONFIG_FILE" '.stacks_base_path')"

if [[ -n "$ARTIFACT_HOST" ]]; then
  BASE_URL="${ARTIFACT_HOST}${STACKS_BASE_PATH}/${STACK}"
else
  ARTIFACT_HOST="$(json_get "$CONFIG_FILE" '.artifact_host')"
  BASE_URL="${ARTIFACT_HOST}${STACKS_BASE_PATH}/${STACK}"
fi

WORKFLOW_FILE_NAME="$WORKFLOW_KEY"
if [[ "$WORKFLOW_FILE_NAME" != *.json ]]; then
  WORKFLOW_FILE_NAME="${WORKFLOW_FILE_NAME}.json"
fi

WORKFLOW_EXISTS=0
while IFS= read -r line; do
  if [[ "$line" == "workflows/${WORKFLOW_FILE_NAME}" ]]; then
    WORKFLOW_EXISTS=1
    break
  fi
done < <(list_workflows "$MANIFEST_FILE" "$STACK")

if (( WORKFLOW_EXISTS == 0 )); then
  echo "Workflow not found in remote manifest: ${WORKFLOW_FILE_NAME}" >&2
  rm -f "$MANIFEST_FILE"
  exit 1
fi

WORKFLOW_FILE="workflows/${WORKFLOW_FILE_NAME}"

REQUIRED_PATHS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && REQUIRED_PATHS+=("$line")
done < <(get_default_required "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME")

OPTIONAL_ALLOWED=()
while IFS= read -r line; do
  [[ -n "$line" ]] && OPTIONAL_ALLOWED+=("$line")
done < <(get_default_optional "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME")

while IFS= read -r line; do
  [[ -n "$line" ]] && OPTIONAL_ALLOWED+=("$line")
done < <(list_optional_pool "$MANIFEST_FILE" "$STACK")

OPTIONAL_SET=()
if (( ${#OPTIONAL_PATHS[@]} > 0 )); then
  for opt in "${OPTIONAL_PATHS[@]}"; do
    local_ok=0
    for allowed in "${OPTIONAL_ALLOWED[@]}"; do
      if [[ "$opt" == "$allowed" ]]; then
        local_ok=1
        break
      fi
    done
    if (( local_ok == 0 )); then
      echo "Optional file not allowed for workflow: ${opt}" >&2
      exit 1
    fi
    OPTIONAL_SET+=("$opt")
  done
fi

DOWNLOAD_LIST=("$WORKFLOW_FILE")
DOWNLOAD_LIST+=("${REQUIRED_PATHS[@]}")
if (( ${#OPTIONAL_SET[@]} > 0 )); then
  DOWNLOAD_LIST+=("${OPTIONAL_SET[@]}")
fi

for path in "${DOWNLOAD_LIST[@]}"; do
  url="${BASE_URL}/${path}"
  target="$(route_target_path "$COMFY_ROOT" "$MODELS_REL" "$WORKFLOWS_REL" "$path")"
  if ! download "$url" "$target"; then
    rm -f "$MANIFEST_FILE"
    exit 1
  fi

  if [[ "$path" == workflows/* ]]; then
    cp -f "$target" "$COMFY_ROOT/$ACTIVE_REL/$(basename "$target")"
  fi
done

summary_file="${COMFY_ROOT}/${WORKFLOWS_REL}/$(basename "$WORKFLOW_FILE")"

log_ts "Downloaded ${#DOWNLOAD_LIST[@]} files into ${COMFY_ROOT}"
log_ts "Workflow activated: ${summary_file}"
rm -f "$MANIFEST_FILE"
