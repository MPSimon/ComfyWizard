#!/usr/bin/env bash
set -Eeuo pipefail

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

detect_comfy_root() {
  local config_file="$1"
  local env_root="${COMFY_ROOT:-}"
  if [[ -n "$env_root" ]]; then
    echo "$env_root"
    return 0
  fi

  local candidate
  for candidate in $(jq -r '.comfy_root_candidates[]' "$config_file"); do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo "/ComfyUI"
}

ensure_workflow_dirs() {
  local comfy_root="$1"
  local workflows_rel="$2"
  local active_rel="$3"
  ensure_dir "$comfy_root/$workflows_rel"
  ensure_dir "$comfy_root/$active_rel"
}

route_target_path() {
  local comfy_root="$1"
  local models_rel="$2"
  local workflows_rel="$3"
  local path="$4"

  local filename
  filename="$(basename "$path")"

  if [[ "$path" == workflows/* ]]; then
    echo "$comfy_root/$workflows_rel/$filename"
  elif [[ "$path" == lora_character/* || "$path" == lora_enhancements/* || "$path" == loras/* ]]; then
    echo "$comfy_root/$models_rel/loras/$filename"
  elif [[ "$path" == artifacts/* ]]; then
    echo "$comfy_root/$models_rel/upscale_models/$filename"
  else
    echo "$comfy_root/$models_rel/$path"
  fi
}
