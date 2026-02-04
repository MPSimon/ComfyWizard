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
