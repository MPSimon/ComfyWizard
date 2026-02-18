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
Usage: bin/sync.sh --stack <wan|qwen> [--workflow <workflow_key>] [--optional <path> ...]

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

WORKFLOW_FILE=""
WORKFLOW_FILE_NAME=""
REQUIRED_PATHS=()
OPTIONAL_ALLOWED=()
HF_REQUIRED_RECORDS=()
HF_REQUIRED_MISSING_RECORDS=()
HF_REQUIRED_FAILED_RECORDS=()
HF_OPTIONAL_RECORDS=()
HF_OPTIONAL_MISSING_RECORDS=()
HF_OPTIONAL_FAILED_RECORDS=()
HF_REQUIRED_TOTAL=0
HF_REQUIRED_PRESENT=0
HF_OPTIONAL_TOTAL=0
HF_OPTIONAL_PRESENT=0
HF_REQUIRED_DOWNLOAD_OK=0
HF_OPTIONAL_DOWNLOAD_OK=0

if [[ -n "$WORKFLOW_KEY" ]]; then
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

  while IFS= read -r line; do
    [[ -n "$line" ]] && REQUIRED_PATHS+=("$line")
  done < <(get_default_required "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME")

  while IFS= read -r line; do
    [[ -n "$line" ]] && OPTIONAL_ALLOWED+=("$line")
  done < <(get_default_optional "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME")

  while IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 label size_bytes; do
    [[ -z "$repo_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    HF_REQUIRED_RECORDS+=("${repo_id}"$'\t'"${filename}"$'\t'"${target_rel_dir}"$'\t'"${revision}"$'\t'"${expected_sha256}")
  done < <(list_workflow_hf_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "required")

  while IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 label size_bytes; do
    [[ -z "$repo_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    HF_OPTIONAL_RECORDS+=("${repo_id}"$'\t'"${filename}"$'\t'"${target_rel_dir}"$'\t'"${revision}"$'\t'"${expected_sha256}")
  done < <(list_workflow_hf_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "optional")
fi

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

DOWNLOAD_LIST=()
if [[ -n "$WORKFLOW_FILE" ]]; then
  DOWNLOAD_LIST+=("$WORKFLOW_FILE")
fi
if (( ${#REQUIRED_PATHS[@]} > 0 )); then
  DOWNLOAD_LIST+=("${REQUIRED_PATHS[@]}")
fi
if (( ${#OPTIONAL_SET[@]} > 0 )); then
  DOWNLOAD_LIST+=("${OPTIONAL_SET[@]}")
fi

if (( ${#HF_REQUIRED_RECORDS[@]} > 0 )); then
  HF_REQUIRED_TOTAL="${#HF_REQUIRED_RECORDS[@]}"
  for rec in "${HF_REQUIRED_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    target="$(hf_target_path "$COMFY_ROOT" "$MODELS_REL" "$target_rel_dir" "$filename")"

    present=0
    if [[ -f "$target" ]]; then
      if [[ -n "$expected_sha256" ]]; then
        actual_sha="$(file_sha256 "$target" || true)"
        if [[ -n "$actual_sha" && "${actual_sha,,}" == "${expected_sha256,,}" ]]; then
          present=1
        fi
      else
        present=1
      fi
    fi

    if (( present == 1 )); then
      HF_REQUIRED_PRESENT=$(( HF_REQUIRED_PRESENT + 1 ))
    else
      HF_REQUIRED_MISSING_RECORDS+=("$rec")
      log_ts "HF requirement missing: ${repo_id}/${filename} -> ${target_rel_dir}"
    fi
  done

  HF_REQUIRED_MISSING=$(( HF_REQUIRED_TOTAL - HF_REQUIRED_PRESENT ))
  log_ts "HF preflight required: total=${HF_REQUIRED_TOTAL} present=${HF_REQUIRED_PRESENT} missing=${HF_REQUIRED_MISSING}"
fi

if (( ${#HF_OPTIONAL_RECORDS[@]} > 0 )); then
  HF_OPTIONAL_TOTAL="${#HF_OPTIONAL_RECORDS[@]}"
  for rec in "${HF_OPTIONAL_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    target="$(hf_target_path "$COMFY_ROOT" "$MODELS_REL" "$target_rel_dir" "$filename")"

    present=0
    if [[ -f "$target" ]]; then
      if [[ -n "$expected_sha256" ]]; then
        actual_sha="$(file_sha256 "$target" || true)"
        if [[ -n "$actual_sha" && "${actual_sha,,}" == "${expected_sha256,,}" ]]; then
          present=1
        fi
      else
        present=1
      fi
    fi

    if (( present == 1 )); then
      HF_OPTIONAL_PRESENT=$(( HF_OPTIONAL_PRESENT + 1 ))
    else
      HF_OPTIONAL_MISSING_RECORDS+=("$rec")
      log_ts "HF optional missing: ${repo_id}/${filename} -> ${target_rel_dir}"
    fi
  done

  HF_OPTIONAL_MISSING=$(( HF_OPTIONAL_TOTAL - HF_OPTIONAL_PRESENT ))
  log_ts "HF preflight optional: total=${HF_OPTIONAL_TOTAL} present=${HF_OPTIONAL_PRESENT} missing=${HF_OPTIONAL_MISSING}"
fi

if (( ${#DOWNLOAD_LIST[@]} == 0 )) && (( ${#HF_REQUIRED_MISSING_RECORDS[@]} == 0 )) && (( ${#HF_OPTIONAL_MISSING_RECORDS[@]} == 0 )); then
  log_ts "Nothing to download."
  rm -f "$MANIFEST_FILE"
  exit 0
fi

HF_MISSING_TOTAL=$(( ${#HF_REQUIRED_MISSING_RECORDS[@]} + ${#HF_OPTIONAL_MISSING_RECORDS[@]} ))
HF_AVAILABLE=1
if (( HF_MISSING_TOTAL > 0 )) && ! command -v hf >/dev/null 2>&1; then
  HF_AVAILABLE=0
  log_ts "WARNING: hf CLI not found; missing HF requirements cannot be downloaded."
fi

if (( ${#HF_REQUIRED_MISSING_RECORDS[@]} > 0 )); then
  for rec in "${HF_REQUIRED_MISSING_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    target="$(hf_target_path "$COMFY_ROOT" "$MODELS_REL" "$target_rel_dir" "$filename")"
    ok=0
    if (( HF_AVAILABLE == 1 )) && hf_download_to_target "$repo_id" "$filename" "$target" "$revision"; then
      if [[ -f "$target" ]]; then
        if [[ -n "$expected_sha256" ]]; then
          actual_sha="$(file_sha256 "$target" || true)"
          if [[ -n "$actual_sha" && "${actual_sha,,}" == "${expected_sha256,,}" ]]; then
            ok=1
          fi
        else
          ok=1
        fi
      fi
    fi

    if (( ok == 1 )); then
      HF_REQUIRED_DOWNLOAD_OK=$(( HF_REQUIRED_DOWNLOAD_OK + 1 ))
    else
      HF_REQUIRED_FAILED_RECORDS+=("$rec")
      log_ts "WARNING: required HF download failed: ${repo_id}/${filename} -> ${target_rel_dir}"
    fi
  done
fi

if (( ${#HF_OPTIONAL_MISSING_RECORDS[@]} > 0 )); then
  for rec in "${HF_OPTIONAL_MISSING_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    target="$(hf_target_path "$COMFY_ROOT" "$MODELS_REL" "$target_rel_dir" "$filename")"
    ok=0
    if (( HF_AVAILABLE == 1 )) && hf_download_to_target "$repo_id" "$filename" "$target" "$revision"; then
      if [[ -f "$target" ]]; then
        if [[ -n "$expected_sha256" ]]; then
          actual_sha="$(file_sha256 "$target" || true)"
          if [[ -n "$actual_sha" && "${actual_sha,,}" == "${expected_sha256,,}" ]]; then
            ok=1
          fi
        else
          ok=1
        fi
      fi
    fi

    if (( ok == 1 )); then
      HF_OPTIONAL_DOWNLOAD_OK=$(( HF_OPTIONAL_DOWNLOAD_OK + 1 ))
    else
      HF_OPTIONAL_FAILED_RECORDS+=("$rec")
      log_ts "WARNING: optional HF download failed: ${repo_id}/${filename} -> ${target_rel_dir}"
    fi
  done
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

log_ts "Downloaded ${#DOWNLOAD_LIST[@]} files into ${COMFY_ROOT}"
if [[ -n "$WORKFLOW_FILE" ]]; then
  summary_file="${COMFY_ROOT}/${WORKFLOWS_REL}/$(basename "$WORKFLOW_FILE")"
  log_ts "Workflow activated: ${summary_file}"
else
  log_ts "Workflow: None"
fi

if (( ${#HF_REQUIRED_RECORDS[@]} > 0 || ${#HF_OPTIONAL_RECORDS[@]} > 0 )); then
  log_ts "HF download summary: required_ok=${HF_REQUIRED_DOWNLOAD_OK} required_failed=${#HF_REQUIRED_FAILED_RECORDS[@]} optional_ok=${HF_OPTIONAL_DOWNLOAD_OK} optional_failed=${#HF_OPTIONAL_FAILED_RECORDS[@]}"
fi

if (( ${#HF_REQUIRED_FAILED_RECORDS[@]} > 0 )); then
  log_ts "WARNING: required HF assets failed:"
  for rec in "${HF_REQUIRED_FAILED_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    log_ts "  - ${repo_id}/${filename} -> ${target_rel_dir}"
  done
  rm -f "$MANIFEST_FILE"
  exit 2
fi

rm -f "$MANIFEST_FILE"
