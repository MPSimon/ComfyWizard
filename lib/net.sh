#!/usr/bin/env bash
set -Eeuo pipefail

log_ts() {
  local msg="$1"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $msg"
}

download() {
  local url="$1"
  local target="$2"
  local tmp="${target}.part"

  local attempt=1
  local max=3
  local backoff=1

  while (( attempt <= max )); do
    log_ts "Downloading ${url} -> ${target} (attempt ${attempt}/${max})"
    mkdir -p "$(dirname "$target")"
    if curl -fL --retry 0 -o "$tmp" "$url"; then
      mv -f "$tmp" "$target"
      return 0
    fi

    rm -f "$tmp"
    if (( attempt == max )); then
      break
    fi

    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    attempt=$(( attempt + 1 ))
  done

  log_ts "Failed to download ${url}"
  return 1
}

hf_download_to_target() {
  local repo_id="$1"
  local filename="$2"
  local target="$3"
  local revision="${4:-}"

  if ! command -v hf >/dev/null 2>&1; then
    log_ts "hf CLI not found; cannot download ${repo_id}/${filename}"
    return 1
  fi

  local out
  local cmd=("hf" "download" "$repo_id" "$filename" "--local-dir" "$(dirname "$target")")
  if [[ -n "$revision" ]]; then
    cmd+=("--revision" "$revision")
  fi

  log_ts "HF downloading ${repo_id}/${filename} -> ${target}"
  if ! out="$("${cmd[@]}" 2>&1)"; then
    log_ts "HF download failed for ${repo_id}/${filename}"
    echo "$out" >&2
    return 1
  fi

  local downloaded_path
  downloaded_path="$(echo "$out" | tail -n 1)"
  if [[ -n "$downloaded_path" && -f "$downloaded_path" ]]; then
    mkdir -p "$(dirname "$target")"
    if [[ "$downloaded_path" != "$target" ]]; then
      cp -f "$downloaded_path" "$target"
    fi
    return 0
  fi

  if [[ -f "$target" ]]; then
    return 0
  fi

  log_ts "HF download output path not found for ${repo_id}/${filename}"
  return 1
}
