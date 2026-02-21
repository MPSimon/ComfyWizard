#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/json.sh"
source "${ROOT_DIR}/lib/fs.sh"
source "${ROOT_DIR}/lib/ui.sh"

install_if_missing() {
  local bin="$1"
  local pkg="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing ${pkg}..."
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y "$pkg" >/dev/null 2>&1 || true
  fi

  if ! command -v "$bin" >/dev/null 2>&1; then
    return 1
  fi
}

if ! install_if_missing jq jq; then
  echo "jq is required but could not be installed." >&2
  exit 1
fi

CONFIG_FILE="${ROOT_DIR}/config/config.json"
MANIFEST_FILE="$(fetch_manifest "$CONFIG_FILE")"

STACKS=()
while IFS= read -r d; do
  [[ -n "$d" ]] && STACKS+=("$d")
done < <(list_stacks "$MANIFEST_FILE")

if (( ${#STACKS[@]} == 0 )); then
  ui_msgbox "No Stacks" "No stacks found in remote manifest"
  exit 1
fi

STACK_MENU=()
for s in "${STACKS[@]}"; do
  STACK_MENU+=("$s" "$s")
done

STACK="$(ui_menu "Stack" "Choose a stack" "${STACK_MENU[@]}")"

if [[ -z "$STACK" ]]; then
  exit 1
fi

WF_FILES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && WF_FILES+=("$line")
done < <(list_workflows "$MANIFEST_FILE" "$STACK")
if (( ${#WF_FILES[@]} == 0 )); then
  ui_msgbox "No Workflows" "No workflow JSON files found in config/stacks/${STACK}/workflows"
  exit 1
fi

MENU_ARGS=()
MENU_ARGS+=("none" "None (skip workflow)")
for f in "${WF_FILES[@]}"; do
  base="$(basename "$f")"
  key="${base%.json}"
  MENU_ARGS+=("$key" "$base")
done

WORKFLOW_KEY="$(ui_menu "Workflow" "Choose a workflow" "${MENU_ARGS[@]}")"
if [[ -z "$WORKFLOW_KEY" ]]; then
  exit 1
fi

WORKFLOW_NONE=0
WORKFLOW_FILE_NAME=""
WORKFLOW_LABEL="None"
REQUIRED_LIST=()
HF_REQUIRED_TOTAL=0
HF_REQUIRED_PRESENT=0
HF_REQUIRED_MISSING=0
if [[ "$WORKFLOW_KEY" != "none" ]]; then
  WORKFLOW_FILE_NAME="${WORKFLOW_KEY}.json"
  WORKFLOW_LABEL="$WORKFLOW_FILE_NAME"
  while IFS= read -r line; do
    [[ -n "$line" ]] && REQUIRED_LIST+=("$line")
  done < <(get_default_required "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME")

  COMFY_ROOT="$(detect_comfy_root "$CONFIG_FILE")"
  MODELS_REL="$(json_get "$CONFIG_FILE" '.models_dir_rel')"
  while IFS=$'\t' read -r source repo_id filename target_rel_dir revision expected_sha256 label size_bytes model_version_id; do
    [[ -z "$repo_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    HF_REQUIRED_TOTAL=$(( HF_REQUIRED_TOTAL + 1 ))
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
    fi
  done < <(list_workflow_hf_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "required")
  HF_REQUIRED_MISSING=$(( HF_REQUIRED_TOTAL - HF_REQUIRED_PRESENT ))
else
  WORKFLOW_NONE=1
fi

OPTIONALS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && OPTIONALS+=("$line")
done < <(list_optional_pool "$MANIFEST_FILE" "$STACK")

FILTERED_OPTIONALS=()
for opt in "${OPTIONALS[@]-}"; do
  skip=0
  for req in "${REQUIRED_LIST[@]-}"; do
    if [[ "$opt" == "$req" ]]; then
      skip=1
      break
    fi
  done
  if (( skip == 0 )); then
    FILTERED_OPTIONALS+=("$opt")
  fi
done
OPTIONALS=()
if [[ -n "${FILTERED_OPTIONALS[*]-}" ]]; then
  OPTIONALS=("${FILTERED_OPTIONALS[@]}")
fi

SELECTED_OPTIONALS=()
if [[ -n "${OPTIONALS[*]-}" ]]; then
  CHECKLIST_ARGS=()
  for opt in "${OPTIONALS[@]-}"; do
    CHECKLIST_ARGS+=("$opt" "$(basename "$opt")" "OFF")
  done
  mapfile -t SELECTED_OPTIONALS < <(ui_checklist "Optional LoRAs" "Select optional files" "${CHECKLIST_ARGS[@]}")
  FILTERED_SELECTED_OPTIONALS=()
  for opt in "${SELECTED_OPTIONALS[@]-}"; do
    if [[ "$opt" =~ [^[:space:]] ]]; then
      FILTERED_SELECTED_OPTIONALS+=("$opt")
    fi
  done
  SELECTED_OPTIONALS=("${FILTERED_SELECTED_OPTIONALS[@]-}")
fi

REQUIRED_COUNT=0
if [[ -n "${REQUIRED_LIST[*]-}" ]]; then
  REQUIRED_COUNT="${#REQUIRED_LIST[@]}"
fi

OPTIONAL_COUNT=0
if [[ -n "${SELECTED_OPTIONALS[*]-}" ]]; then
  OPTIONAL_COUNT="${#SELECTED_OPTIONALS[@]}"
fi

DOWNLOAD_PATHS=()
if (( WORKFLOW_NONE == 0 )); then
  WORKFLOW_FILE_PATH="workflows/${WORKFLOW_FILE_NAME}"
  DOWNLOAD_PATHS+=("$WORKFLOW_FILE_PATH")
  if (( ${#REQUIRED_LIST[@]} > 0 )); then
    DOWNLOAD_PATHS+=("${REQUIRED_LIST[@]}")
  fi
fi
if [[ -n "${SELECTED_OPTIONALS[*]-}" ]]; then
  DOWNLOAD_PATHS+=("${SELECTED_OPTIONALS[@]}")
fi

SIZE_ESTIMATE=""

SUMMARY="Stack: ${STACK}\nWorkflow: ${WORKFLOW_LABEL}\nRequired files: ${REQUIRED_COUNT}\nHF required: ${HF_REQUIRED_TOTAL} (present: ${HF_REQUIRED_PRESENT}, to download: ${HF_REQUIRED_MISSING})\nOptional selected: ${OPTIONAL_COUNT}"

if ! ui_yesno "Confirm" "$SUMMARY"; then
  exit 1
fi

SYNC_ARGS=("${ROOT_DIR}/bin/sync.sh" --stack "$STACK")
if (( WORKFLOW_NONE == 0 )); then
  SYNC_ARGS+=(--workflow "$WORKFLOW_KEY")
fi
for opt in "${SELECTED_OPTIONALS[@]-}"; do
  if [[ "$opt" =~ [^[:space:]] ]]; then
    SYNC_ARGS+=(--optional "$opt")
  fi
done

if "${SYNC_ARGS[@]}"; then
  ui_msgbox "Done" "Workflow activated in ComfyUI workflows/Active."
else
  ui_msgbox "Error" "Sync failed. See logs above."
  exit 1
fi

rm -f "$MANIFEST_FILE"
