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

list_workflows() {
  local stack="$1"
  local dir="config/stacks/${stack}/workflows"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  find "$dir" -maxdepth 1 -type f -name '*.json' -print | sort
}

get_default_required() {
  local stack="$1"
  local workflow_file="$2"
  local defaults_file="config/stacks/${stack}/manifest.json"
  require_jq
  jq -r --arg wf "$workflow_file" '.defaults[$wf].required[]?' "$defaults_file"
}

get_default_optional() {
  local stack="$1"
  local workflow_file="$2"
  local defaults_file="config/stacks/${stack}/manifest.json"
  require_jq
  jq -r --arg wf "$workflow_file" '.defaults[$wf].optional[]?' "$defaults_file"
}
