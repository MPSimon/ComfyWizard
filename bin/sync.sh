#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/json.sh"
source "${ROOT_DIR}/lib/fs.sh"
source "${ROOT_DIR}/lib/net.sh"

supports_color() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    return 1
  fi
  if [[ -n "${FORCE_COLOR:-}" || -n "${CLICOLOR_FORCE:-}" ]]; then
    return 0
  fi
  [[ -t 1 ]]
}

colorize() {
  local code="$1"
  shift
  local msg="$*"
  if supports_color; then
    printf '\033[%sm%s\033[0m' "$code" "$msg"
  else
    printf '%s' "$msg"
  fi
}

log_warn() {
  log_ts "$(colorize "1;33" "WARNING: $*")"
}

log_error() {
  log_ts "$(colorize "1;31" "ERROR: $*")"
}

log_section() {
  local title="$1"
  local bar="============================================================"
  log_ts "$(colorize "1;36" "$bar")"
  log_ts "$(colorize "1;36" "$title")"
  log_ts "$(colorize "1;36" "$bar")"
}

hf_display_name() {
  local filename="$1"
  basename "$filename"
}

UI_MODE=0
if [[ -t 1 ]]; then
  UI_MODE=1
fi

HF_KEYS=()
HF_REQUIRED_FLAGS=()
HF_STATES=()
HF_DETAILS=()
HF_HEARTBEAT_ACTIVE=0

hf_key() {
  local repo_id="$1"
  local filename="$2"
  local target_rel_dir="$3"
  local revision="$4"
  echo "${repo_id}|${filename}|${target_rel_dir}|${revision}"
}

hf_state_index() {
  local key="$1"
  local i
  for i in "${!HF_KEYS[@]}"; do
    if [[ "${HF_KEYS[$i]}" == "$key" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo "-1"
}

hf_register() {
  local key="$1"
  local required="$2"
  local state="$3"
  local detail="${4:-}"
  HF_KEYS+=("$key")
  HF_REQUIRED_FLAGS+=("$required")
  HF_STATES+=("$state")
  HF_DETAILS+=("$detail")
}

hf_set_state() {
  local key="$1"
  local state="$2"
  local detail="${3:-}"
  local idx
  idx="$(hf_state_index "$key")"
  if [[ "$idx" == "-1" ]]; then
    return 0
  fi
  HF_STATES[$idx]="$state"
  if [[ -n "$detail" ]]; then
    HF_DETAILS[$idx]="$detail"
  fi
}

hf_count_state() {
  local state="$1"
  local count=0
  local i
  for i in "${!HF_STATES[@]}"; do
    if [[ "${HF_STATES[$i]}" == "$state" ]]; then
      count=$(( count + 1 ))
    fi
  done
  echo "$count"
}

hf_clear_heartbeat_line() {
  if (( UI_MODE == 1 )) && [[ -t 1 ]] && (( HF_HEARTBEAT_ACTIVE == 1 )); then
    printf '\r%*s\r' 140 ''
    HF_HEARTBEAT_ACTIVE=0
  fi
}

hf_render_heartbeat() {
  local current_label="$1"
  local elapsed="$2"
  local done_count skipped_count failed_count pending_count downloading_count
  done_count="$(hf_count_state "DONE")"
  skipped_count="$(hf_count_state "SKIPPED")"
  failed_count="$(hf_count_state "FAILED")"
  pending_count="$(hf_count_state "PENDING")"
  downloading_count="$(hf_count_state "DOWNLOADING")"
  local line
  line="HF: done=${done_count} skipped=${skipped_count} failed=${failed_count} pending=${pending_count} downloading=${downloading_count} current=${current_label} t=${elapsed}s"
  if (( UI_MODE == 1 )) && [[ -t 1 ]]; then
    printf '\r%-140s' "$line"
    HF_HEARTBEAT_ACTIVE=1
  else
    log_ts "$line"
  fi
}

hf_line_callback() {
  local repo_id="$1"
  local filename="$2"
  local line="$3"
  local clean="${line//$'\r'/}"
  [[ -z "$clean" ]] && return 0
  if [[ "$clean" == *"Error"* || "$clean" == *"Downloading"* || "$clean" == *"Fetching"* || "$clean" == *"%"* ]]; then
    hf_clear_heartbeat_line
    log_ts "HF ${repo_id}/${filename}: ${clean}"
  fi
}

hf_heartbeat_callback() {
  local repo_id="$1"
  local filename="$2"
  local elapsed="$3"
  hf_render_heartbeat "${repo_id}/$(basename "$filename")" "$elapsed"
}

hf_run_worker() {
  local rec="$1"
  local required="$2"
  IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
  local target
  target="$(hf_target_path "$COMFY_ROOT" "$MODELS_REL" "$target_rel_dir" "$filename")"

  if ! hf_download_to_target "$repo_id" "$filename" "$target" "$revision" "hf_line_callback" ""; then
    return 1
  fi

  if [[ ! -f "$target" ]]; then
    return 1
  fi

  if [[ -n "$expected_sha256" ]]; then
    local actual_sha
    actual_sha="$(file_sha256 "$target" || true)"
    if [[ -z "$actual_sha" || "${actual_sha,,}" != "${expected_sha256,,}" ]]; then
      return 1
    fi
  fi

  return 0
}

hf_download_group() {
  local array_name="$1"
  local required_flag="$2"
  local title="$3"
  local records_ref=()
  eval "records_ref=(\"\${${array_name}[@]}\")"
  local total="${#records_ref[@]}"
  if (( total == 0 )); then
    return 0
  fi

  log_section "$title"

  local idx=0
  local running_pids=()
  local running_keys=()
  local running_recs=()
  local running_starts=()
  local running_names=()

  launch_one() {
    local rec="$1"
    idx=$(( idx + 1 ))
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    local key display_name
    key="$(hf_key "$repo_id" "$filename" "$target_rel_dir" "$revision")"
    display_name="$(hf_display_name "$filename")"
    hf_set_state "$key" "DOWNLOADING" "starting download"
    log_ts "HF [${idx}/${total}] ${display_name} -> ${target_rel_dir}"

    local start_ts="$SECONDS"
    hf_run_worker "$rec" "$required_flag" &
    local pid=$!

    running_pids+=("$pid")
    running_keys+=("$key")
    running_recs+=("$rec")
    running_starts+=("$start_ts")
    running_names+=("$display_name")
  }

  reap_finished() {
    local progressed=0
    local i
    for (( i=0; i<${#running_pids[@]}; i++ )); do
      local pid="${running_pids[$i]}"
      [[ -z "$pid" ]] && continue
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        set +e
        wait "$pid"
        local rc=$?
        set -e

        local item_elapsed=$(( SECONDS - running_starts[i] ))
        local rec="${running_recs[$i]}"
        local key="${running_keys[$i]}"
        local display_name="${running_names[$i]}"
        IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"

        if [[ "$required_flag" == "1" ]]; then
          HF_REQUIRED_DOWNLOAD_SECONDS=$(( HF_REQUIRED_DOWNLOAD_SECONDS + item_elapsed ))
        else
          HF_OPTIONAL_DOWNLOAD_SECONDS=$(( HF_OPTIONAL_DOWNLOAD_SECONDS + item_elapsed ))
        fi

        if (( rc == 0 )); then
          if [[ "$required_flag" == "1" ]]; then
            HF_REQUIRED_DOWNLOAD_OK=$(( HF_REQUIRED_DOWNLOAD_OK + 1 ))
          else
            HF_OPTIONAL_DOWNLOAD_OK=$(( HF_OPTIONAL_DOWNLOAD_OK + 1 ))
          fi
          hf_set_state "$key" "DONE" "downloaded"
          hf_clear_heartbeat_line
          log_ts "HF done: ${display_name} (${item_elapsed}s)"
        else
          if [[ "$required_flag" == "1" ]]; then
            HF_REQUIRED_FAILED_RECORDS+=("$rec")
            hf_clear_heartbeat_line
            log_warn "required HF download failed: ${display_name} -> ${target_rel_dir}"
          else
            HF_OPTIONAL_FAILED_RECORDS+=("$rec")
            hf_clear_heartbeat_line
            log_warn "optional HF download failed: ${display_name} -> ${target_rel_dir}"
          fi
          hf_set_state "$key" "FAILED" "download failed"
        fi

        running_pids[$i]=""
        running_keys[$i]=""
        running_recs[$i]=""
        running_starts[$i]=""
        running_names[$i]=""
        progressed=1
      fi
    done
    if (( progressed == 1 )); then
      return 0
    fi
    return 1
  }

  for rec in "${records_ref[@]-}"; do
    while :; do
      local active=0
      local p
      for p in "${running_pids[@]-}"; do
        [[ -n "$p" ]] && active=$(( active + 1 ))
      done
      if (( active < HF_CONCURRENCY )); then
        break
      fi
      if ! reap_finished; then
        hf_render_heartbeat "$title" "$(( SECONDS - SYNC_START_SECONDS ))"
        sleep 3
      else
        hf_clear_heartbeat_line
      fi
    done
    launch_one "$rec"
  done

  while :; do
    local active=0
    local p
    for p in "${running_pids[@]-}"; do
      [[ -n "$p" ]] && active=$(( active + 1 ))
    done
    if (( active == 0 )); then
      break
    fi
    if ! reap_finished; then
      hf_render_heartbeat "$title" "$(( SECONDS - SYNC_START_SECONDS ))"
      sleep 3
    else
      hf_clear_heartbeat_line
    fi
  done
}

civitai_display_name() {
  local filename="$1"
  basename "$filename"
}

civitai_run_worker() {
  local rec="$1"
  IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
  local target
  target="$(hf_target_path "$COMFY_ROOT" "$MODELS_REL" "$target_rel_dir" "$filename")"

  if ! civitai_download_to_target "$model_version_id" "$filename" "$target" "" ""; then
    return 1
  fi

  if [[ ! -f "$target" ]]; then
    return 1
  fi

  if [[ -n "$expected_sha256" ]]; then
    local actual_sha
    actual_sha="$(file_sha256 "$target" || true)"
    if [[ -z "$actual_sha" || "${actual_sha,,}" != "${expected_sha256,,}" ]]; then
      return 1
    fi
  fi

  return 0
}

STACK=""
WORKFLOW_KEY=""
OPTIONAL_PATHS=()
OPTIONAL_SET=()

usage() {
  cat <<USAGE
Usage: bin/sync.sh --stack <wan|qwen> [--workflow <workflow_key>] [--optional <path> ...]

Flags:
  --ui        Enable interactive status output (default when TTY)
  --no-ui     Disable interactive status output

Env overrides:
  ARTIFACT_HOST  Override config artifact_host
  COMFY_ROOT     Force comfy root path
  CIVITAI_TOKEN  Required for Civitai workflow requirements
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
    --ui)
      UI_MODE=1; shift 1;;
    --no-ui)
      UI_MODE=0; shift 1;;
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

HF_CONCURRENCY="${HF_CONCURRENCY:-3}"

if ! [[ "$HF_CONCURRENCY" =~ ^[0-9]+$ ]] || (( HF_CONCURRENCY < 1 )); then
  echo "HF_CONCURRENCY must be a positive integer (current: ${HF_CONCURRENCY})" >&2
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
HF_REQUIRED_DOWNLOAD_SECONDS=0
HF_OPTIONAL_DOWNLOAD_SECONDS=0
CIVITAI_REQUIRED_RECORDS=()
CIVITAI_REQUIRED_MISSING_RECORDS=()
CIVITAI_REQUIRED_FAILED_RECORDS=()
CIVITAI_OPTIONAL_RECORDS=()
CIVITAI_OPTIONAL_MISSING_RECORDS=()
CIVITAI_OPTIONAL_FAILED_RECORDS=()
CIVITAI_REQUIRED_TOTAL=0
CIVITAI_REQUIRED_PRESENT=0
CIVITAI_OPTIONAL_TOTAL=0
CIVITAI_OPTIONAL_PRESENT=0
CIVITAI_REQUIRED_DOWNLOAD_OK=0
CIVITAI_OPTIONAL_DOWNLOAD_OK=0
CIVITAI_REQUIRED_DOWNLOAD_SECONDS=0
CIVITAI_OPTIONAL_DOWNLOAD_SECONDS=0
PRIVATE_DOWNLOAD_SECONDS=0
SYNC_START_SECONDS=$SECONDS

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

  while IFS=$'\t' read -r source repo_id filename target_rel_dir revision expected_sha256 label size_bytes model_version_id; do
    [[ -z "$repo_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    HF_REQUIRED_RECORDS+=("${repo_id}"$'\t'"${filename}"$'\t'"${target_rel_dir}"$'\t'"${revision}"$'\t'"${expected_sha256}")
  done < <(list_workflow_hf_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "required")

  while IFS=$'\t' read -r source repo_id filename target_rel_dir revision expected_sha256 label size_bytes model_version_id; do
    [[ -z "$repo_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    HF_OPTIONAL_RECORDS+=("${repo_id}"$'\t'"${filename}"$'\t'"${target_rel_dir}"$'\t'"${revision}"$'\t'"${expected_sha256}")
  done < <(list_workflow_hf_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "optional")

  while IFS=$'\t' read -r source repo_id filename target_rel_dir revision expected_sha256 label size_bytes model_version_id; do
    [[ -z "$model_version_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    CIVITAI_REQUIRED_RECORDS+=("${model_version_id}"$'\t'"${filename}"$'\t'"${target_rel_dir}"$'\t'"${expected_sha256}")
  done < <(list_workflow_civitai_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "required")

  while IFS=$'\t' read -r source repo_id filename target_rel_dir revision expected_sha256 label size_bytes model_version_id; do
    [[ -z "$model_version_id" || -z "$filename" || -z "$target_rel_dir" ]] && continue
    CIVITAI_OPTIONAL_RECORDS+=("${model_version_id}"$'\t'"${filename}"$'\t'"${target_rel_dir}"$'\t'"${expected_sha256}")
  done < <(list_workflow_civitai_requirements "$MANIFEST_FILE" "$STACK" "$WORKFLOW_FILE_NAME" "optional")
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
  log_section "HF preflight (required)"
  HF_REQUIRED_TOTAL="${#HF_REQUIRED_RECORDS[@]}"
  for rec in "${HF_REQUIRED_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    key="$(hf_key "$repo_id" "$filename" "$target_rel_dir" "$revision")"
    display_name="$(hf_display_name "$filename")"
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
      hf_register "$key" "1" "SKIPPED" "already present"
    else
      HF_REQUIRED_MISSING_RECORDS+=("$rec")
      hf_register "$key" "1" "PENDING" "waiting to download"
      log_ts "HF requirement missing: ${display_name} -> ${target_rel_dir}"
    fi
  done

  HF_REQUIRED_MISSING=$(( HF_REQUIRED_TOTAL - HF_REQUIRED_PRESENT ))
  log_ts "HF preflight required: total=${HF_REQUIRED_TOTAL} present=${HF_REQUIRED_PRESENT} missing=${HF_REQUIRED_MISSING}"
fi

if (( ${#HF_OPTIONAL_RECORDS[@]} > 0 )); then
  log_section "HF preflight (optional)"
  HF_OPTIONAL_TOTAL="${#HF_OPTIONAL_RECORDS[@]}"
  for rec in "${HF_OPTIONAL_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    key="$(hf_key "$repo_id" "$filename" "$target_rel_dir" "$revision")"
    display_name="$(hf_display_name "$filename")"
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
      hf_register "$key" "0" "SKIPPED" "already present"
    else
      HF_OPTIONAL_MISSING_RECORDS+=("$rec")
      hf_register "$key" "0" "PENDING" "waiting to download"
      log_ts "HF optional missing: ${display_name} -> ${target_rel_dir}"
    fi
  done

  HF_OPTIONAL_MISSING=$(( HF_OPTIONAL_TOTAL - HF_OPTIONAL_PRESENT ))
  log_ts "HF preflight optional: total=${HF_OPTIONAL_TOTAL} present=${HF_OPTIONAL_PRESENT} missing=${HF_OPTIONAL_MISSING}"
fi

if (( ${#CIVITAI_REQUIRED_RECORDS[@]} > 0 )); then
  log_section "Civitai preflight (required)"
  CIVITAI_REQUIRED_TOTAL="${#CIVITAI_REQUIRED_RECORDS[@]}"
  for rec in "${CIVITAI_REQUIRED_RECORDS[@]}"; do
    IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
    display_name="$(civitai_display_name "$filename")"
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
      CIVITAI_REQUIRED_PRESENT=$(( CIVITAI_REQUIRED_PRESENT + 1 ))
    else
      CIVITAI_REQUIRED_MISSING_RECORDS+=("$rec")
      log_ts "Civitai requirement missing: ${display_name} -> ${target_rel_dir}"
    fi
  done
  CIVITAI_REQUIRED_MISSING=$(( CIVITAI_REQUIRED_TOTAL - CIVITAI_REQUIRED_PRESENT ))
  log_ts "Civitai preflight required: total=${CIVITAI_REQUIRED_TOTAL} present=${CIVITAI_REQUIRED_PRESENT} missing=${CIVITAI_REQUIRED_MISSING}"
fi

if (( ${#CIVITAI_OPTIONAL_RECORDS[@]} > 0 )); then
  log_section "Civitai preflight (optional)"
  CIVITAI_OPTIONAL_TOTAL="${#CIVITAI_OPTIONAL_RECORDS[@]}"
  for rec in "${CIVITAI_OPTIONAL_RECORDS[@]}"; do
    IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
    display_name="$(civitai_display_name "$filename")"
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
      CIVITAI_OPTIONAL_PRESENT=$(( CIVITAI_OPTIONAL_PRESENT + 1 ))
    else
      CIVITAI_OPTIONAL_MISSING_RECORDS+=("$rec")
      log_ts "Civitai optional missing: ${display_name} -> ${target_rel_dir}"
    fi
  done
  CIVITAI_OPTIONAL_MISSING=$(( CIVITAI_OPTIONAL_TOTAL - CIVITAI_OPTIONAL_PRESENT ))
  log_ts "Civitai preflight optional: total=${CIVITAI_OPTIONAL_TOTAL} present=${CIVITAI_OPTIONAL_PRESENT} missing=${CIVITAI_OPTIONAL_MISSING}"
fi

if (( ${#DOWNLOAD_LIST[@]} == 0 )) \
  && (( ${#HF_REQUIRED_MISSING_RECORDS[@]} == 0 )) \
  && (( ${#HF_OPTIONAL_MISSING_RECORDS[@]} == 0 )) \
  && (( ${#CIVITAI_REQUIRED_MISSING_RECORDS[@]} == 0 )) \
  && (( ${#CIVITAI_OPTIONAL_MISSING_RECORDS[@]} == 0 )); then
  log_ts "Nothing to download."
  rm -f "$MANIFEST_FILE"
  exit 0
fi

HF_MISSING_TOTAL=$(( ${#HF_REQUIRED_MISSING_RECORDS[@]} + ${#HF_OPTIONAL_MISSING_RECORDS[@]} ))
HF_AVAILABLE=1
if (( HF_MISSING_TOTAL > 0 )) && ! command -v hf >/dev/null 2>&1; then
  HF_AVAILABLE=0
  log_warn "hf CLI not found; missing HF requirements cannot be downloaded."
  for rec in "${HF_REQUIRED_MISSING_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    key="$(hf_key "$repo_id" "$filename" "$target_rel_dir" "$revision")"
    hf_set_state "$key" "FAILED" "hf CLI missing"
  done
  for rec in "${HF_OPTIONAL_MISSING_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    key="$(hf_key "$repo_id" "$filename" "$target_rel_dir" "$revision")"
    hf_set_state "$key" "FAILED" "hf CLI missing"
  done
fi

if (( ${#HF_REQUIRED_MISSING_RECORDS[@]} > 0 )) && (( HF_AVAILABLE == 1 )); then
  hf_download_group HF_REQUIRED_MISSING_RECORDS "1" "HF downloads (required, concurrency=${HF_CONCURRENCY})"
fi

if (( ${#HF_OPTIONAL_MISSING_RECORDS[@]} > 0 )) && (( HF_AVAILABLE == 1 )); then
  hf_download_group HF_OPTIONAL_MISSING_RECORDS "0" "HF downloads (optional, concurrency=${HF_CONCURRENCY})"
fi

CIVITAI_MISSING_TOTAL=$(( ${#CIVITAI_REQUIRED_MISSING_RECORDS[@]} + ${#CIVITAI_OPTIONAL_MISSING_RECORDS[@]} ))
CIVITAI_AVAILABLE=1
if (( CIVITAI_MISSING_TOTAL > 0 )) && [[ -z "${CIVITAI_TOKEN:-}" ]]; then
  CIVITAI_AVAILABLE=0
  log_warn "CIVITAI_TOKEN not set; missing Civitai requirements cannot be downloaded."
  for rec in "${CIVITAI_REQUIRED_MISSING_RECORDS[@]}"; do
    CIVITAI_REQUIRED_FAILED_RECORDS+=("$rec")
  done
  for rec in "${CIVITAI_OPTIONAL_MISSING_RECORDS[@]}"; do
    CIVITAI_OPTIONAL_FAILED_RECORDS+=("$rec")
  done
fi

if (( ${#CIVITAI_REQUIRED_MISSING_RECORDS[@]} > 0 )) && (( CIVITAI_AVAILABLE == 1 )); then
  log_section "Civitai downloads (required)"
  for rec in "${CIVITAI_REQUIRED_MISSING_RECORDS[@]}"; do
    item_start=$SECONDS
    IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
    display_name="$(civitai_display_name "$filename")"
    log_ts "Civitai required: ${display_name} -> ${target_rel_dir}"
    if civitai_run_worker "$rec"; then
      CIVITAI_REQUIRED_DOWNLOAD_OK=$(( CIVITAI_REQUIRED_DOWNLOAD_OK + 1 ))
      log_ts "Civitai done: ${display_name}"
    else
      CIVITAI_REQUIRED_FAILED_RECORDS+=("$rec")
      log_warn "required Civitai download failed: ${display_name} -> ${target_rel_dir}"
    fi
    CIVITAI_REQUIRED_DOWNLOAD_SECONDS=$(( CIVITAI_REQUIRED_DOWNLOAD_SECONDS + (SECONDS - item_start) ))
  done
fi

if (( ${#CIVITAI_OPTIONAL_MISSING_RECORDS[@]} > 0 )) && (( CIVITAI_AVAILABLE == 1 )); then
  log_section "Civitai downloads (optional)"
  for rec in "${CIVITAI_OPTIONAL_MISSING_RECORDS[@]}"; do
    item_start=$SECONDS
    IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
    display_name="$(civitai_display_name "$filename")"
    log_ts "Civitai optional: ${display_name} -> ${target_rel_dir}"
    if civitai_run_worker "$rec"; then
      CIVITAI_OPTIONAL_DOWNLOAD_OK=$(( CIVITAI_OPTIONAL_DOWNLOAD_OK + 1 ))
      log_ts "Civitai done: ${display_name}"
    else
      CIVITAI_OPTIONAL_FAILED_RECORDS+=("$rec")
      log_warn "optional Civitai download failed: ${display_name} -> ${target_rel_dir}"
    fi
    CIVITAI_OPTIONAL_DOWNLOAD_SECONDS=$(( CIVITAI_OPTIONAL_DOWNLOAD_SECONDS + (SECONDS - item_start) ))
  done
fi

if (( ${#DOWNLOAD_LIST[@]} > 0 )); then
  log_section "Private artifact downloads"
fi
for path in "${DOWNLOAD_LIST[@]}"; do
  item_start=$SECONDS
  url="${BASE_URL}/${path}"
  target="$(route_target_path "$COMFY_ROOT" "$MODELS_REL" "$WORKFLOWS_REL" "$path")"
  if ! download "$url" "$target"; then
    rm -f "$MANIFEST_FILE"
    exit 1
  fi

  if [[ "$path" == workflows/* ]]; then
    cp -f "$target" "$COMFY_ROOT/$ACTIVE_REL/$(basename "$target")"
  fi
  PRIVATE_DOWNLOAD_SECONDS=$(( PRIVATE_DOWNLOAD_SECONDS + (SECONDS - item_start) ))
done

log_ts "Downloaded ${#DOWNLOAD_LIST[@]} files into ${COMFY_ROOT}"
if [[ -n "$WORKFLOW_FILE" ]]; then
  summary_file="${COMFY_ROOT}/${WORKFLOWS_REL}/$(basename "$WORKFLOW_FILE")"
  log_ts "Workflow activated: ${summary_file}"
else
  log_ts "Workflow: None"
fi

if (( ${#HF_KEYS[@]} > 0 )); then
  log_section "HF summary"
  hf_done_count="$(hf_count_state "DONE")"
  hf_skipped_count="$(hf_count_state "SKIPPED")"
  hf_failed_count="$(hf_count_state "FAILED")"
  hf_pending_count="$(hf_count_state "PENDING")"
  log_ts "HF state summary: done=${hf_done_count} skipped=${hf_skipped_count} failed=${hf_failed_count} pending=${hf_pending_count}"
fi

if (( ${#HF_REQUIRED_RECORDS[@]} > 0 || ${#HF_OPTIONAL_RECORDS[@]} > 0 )); then
  log_ts "HF download summary: required_ok=${HF_REQUIRED_DOWNLOAD_OK} required_failed=${#HF_REQUIRED_FAILED_RECORDS[@]} optional_ok=${HF_OPTIONAL_DOWNLOAD_OK} optional_failed=${#HF_OPTIONAL_FAILED_RECORDS[@]}"
  log_ts "HF timing: required=${HF_REQUIRED_DOWNLOAD_SECONDS}s optional=${HF_OPTIONAL_DOWNLOAD_SECONDS}s"
fi

if (( ${#CIVITAI_REQUIRED_RECORDS[@]} > 0 || ${#CIVITAI_OPTIONAL_RECORDS[@]} > 0 )); then
  log_ts "Civitai download summary: required_ok=${CIVITAI_REQUIRED_DOWNLOAD_OK} required_failed=${#CIVITAI_REQUIRED_FAILED_RECORDS[@]} optional_ok=${CIVITAI_OPTIONAL_DOWNLOAD_OK} optional_failed=${#CIVITAI_OPTIONAL_FAILED_RECORDS[@]}"
  log_ts "Civitai timing: required=${CIVITAI_REQUIRED_DOWNLOAD_SECONDS}s optional=${CIVITAI_OPTIONAL_DOWNLOAD_SECONDS}s"
fi

if (( ${#HF_REQUIRED_FAILED_RECORDS[@]} > 0 )); then
  log_error "required HF assets failed:"
  for rec in "${HF_REQUIRED_FAILED_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    log_error "  - ${repo_id}/${filename} -> ${target_rel_dir}"
  done
  if (( ${#HF_OPTIONAL_FAILED_RECORDS[@]} > 0 )); then
    log_warn "optional HF assets failed:"
    for rec in "${HF_OPTIONAL_FAILED_RECORDS[@]}"; do
      IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
      log_warn "  - ${repo_id}/${filename} -> ${target_rel_dir}"
    done
  fi
  rm -f "$MANIFEST_FILE"
  exit 2
fi

if (( ${#CIVITAI_REQUIRED_FAILED_RECORDS[@]} > 0 )); then
  log_error "required Civitai assets failed:"
  for rec in "${CIVITAI_REQUIRED_FAILED_RECORDS[@]}"; do
    IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
    log_error "  - model_version_id=${model_version_id} file=${filename} -> ${target_rel_dir}"
  done
  if (( ${#CIVITAI_OPTIONAL_FAILED_RECORDS[@]} > 0 )); then
    log_warn "optional Civitai assets failed:"
    for rec in "${CIVITAI_OPTIONAL_FAILED_RECORDS[@]}"; do
      IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
      log_warn "  - model_version_id=${model_version_id} file=${filename} -> ${target_rel_dir}"
    done
  fi
  rm -f "$MANIFEST_FILE"
  exit 2
fi

if (( ${#HF_OPTIONAL_FAILED_RECORDS[@]} > 0 )); then
  log_warn "optional HF assets failed:"
  for rec in "${HF_OPTIONAL_FAILED_RECORDS[@]}"; do
    IFS=$'\t' read -r repo_id filename target_rel_dir revision expected_sha256 <<< "$rec"
    log_warn "  - ${repo_id}/${filename} -> ${target_rel_dir}"
  done
fi

if (( ${#CIVITAI_OPTIONAL_FAILED_RECORDS[@]} > 0 )); then
  log_warn "optional Civitai assets failed:"
  for rec in "${CIVITAI_OPTIONAL_FAILED_RECORDS[@]}"; do
    IFS=$'\t' read -r model_version_id filename target_rel_dir expected_sha256 <<< "$rec"
    log_warn "  - model_version_id=${model_version_id} file=${filename} -> ${target_rel_dir}"
  done
fi

log_section "Sync complete"
log_ts "Total runtime: $(( SECONDS - SYNC_START_SECONDS ))s"
log_ts "Download timing: hf_required=${HF_REQUIRED_DOWNLOAD_SECONDS}s hf_optional=${HF_OPTIONAL_DOWNLOAD_SECONDS}s civitai_required=${CIVITAI_REQUIRED_DOWNLOAD_SECONDS}s civitai_optional=${CIVITAI_OPTIONAL_DOWNLOAD_SECONDS}s private=${PRIVATE_DOWNLOAD_SECONDS}s"

rm -f "$MANIFEST_FILE"
