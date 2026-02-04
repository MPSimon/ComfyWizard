#!/usr/bin/env bash
set -Eeuo pipefail

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not installed." >&2
    return 1
  fi
}

json_get() {
  local file="$1"
  local query="$2"
  require_jq
  jq -r "$query" "$file"
}

manifest_url() {
  local config_file="$1"
  if [[ -n "${MANIFEST_URL:-}" ]]; then
    echo "${MANIFEST_URL}"
    return 0
  fi
  local host
  local path
  host="$(json_get "$config_file" '.artifact_host')"
  path="$(json_get "$config_file" '.manifest_path')"
  echo "${host}${path}"
}

fetch_manifest() {
  local config_file="$1"
  local url
  url="$(manifest_url "$config_file")"
  local tmp
  tmp="$(mktemp)"

  local curl_args=("-fsSL")
  if [[ -n "${ARTIFACT_AUTH:-}" ]]; then
    curl_args+=("-H" "Authorization: ${ARTIFACT_AUTH}")
  fi
  curl "${curl_args[@]}" "$url" -o "$tmp"
  echo "$tmp"
}

list_stacks() {
  local manifest_file="$1"
  require_jq
  jq -r '.stacks | keys[]' "$manifest_file"
}

list_workflows() {
  local manifest_file="$1"
  local stack="$2"
  require_jq
  jq -r --arg stack "$stack" '.stacks[$stack].workflows[]?' "$manifest_file"
}

get_default_required() {
  local manifest_file="$1"
  local stack="$2"
  local workflow_file="$3"
  require_jq
  jq -r --arg stack "$stack" --arg wf "$workflow_file" '.stacks[$stack].defaults[$wf].required[]?' "$manifest_file"
}

get_default_optional() {
  local manifest_file="$1"
  local stack="$2"
  local workflow_file="$3"
  require_jq
  jq -r --arg stack "$stack" --arg wf "$workflow_file" '.stacks[$stack].defaults[$wf].optional[]?' "$manifest_file"
}

list_optional_pool() {
  local manifest_file="$1"
  local stack="$2"
  require_jq
  jq -r --arg stack "$stack" '.stacks[$stack] | (.lora_character // []) + (.lora_enhancements // []) + (.upscale_models // []) | .[]' "$manifest_file"
}
