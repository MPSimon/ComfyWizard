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
  local name
  name="$(basename "$target")"

  local attempt=1
  local max=3
  local backoff=1

  while (( attempt <= max )); do
    log_ts "Downloading ${name} (attempt ${attempt}/${max})"
    mkdir -p "$(dirname "$target")"
    set +e
    curl -fsSL --retry 0 -o "$tmp" "$url" &
    local curl_pid=$!
    local elapsed=0
    while kill -0 "$curl_pid" >/dev/null 2>&1; do
      if [[ -t 1 ]]; then
        printf '\r[%s] Downloading %s ... t=%ss' "$(date +"%Y-%m-%d %H:%M:%S")" "$name" "$elapsed"
      else
        log_ts "Downloading ${name} ... t=${elapsed}s"
      fi
      sleep 2
      elapsed=$(( elapsed + 2 ))
    done
    wait "$curl_pid"
    local rc=$?
    set -e
    if [[ -t 1 ]]; then
      printf '\r%*s\r' 140 ''
    fi

    if (( rc == 0 )); then
      mv -f "$tmp" "$target"
      local size_bytes
      size_bytes="$(wc -c <"$target" | tr -d ' ')"
      log_ts "Downloaded ${name} (${size_bytes} bytes)"
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
  local line_callback="${5:-}"
  local heartbeat_callback="${6:-}"

  if ! command -v hf >/dev/null 2>&1; then
    log_ts "hf CLI not found; cannot download ${repo_id}/${filename}"
    return 1
  fi

  local out_file
  out_file="$(mktemp)"
  local cmd=("hf" "download" "$repo_id" "$filename" "--local-dir" "$(dirname "$target")")
  if [[ -n "$revision" ]]; then
    cmd+=("--revision" "$revision")
  fi

  set +e
  "${cmd[@]}" >"$out_file" 2>&1 &
  local hf_pid=$!
  local line_no=0
  local elapsed=0
  while kill -0 "$hf_pid" >/dev/null 2>&1; do
    local total_lines
    total_lines="$(wc -l <"$out_file" | tr -d ' ')"
    if (( total_lines > line_no )); then
      while IFS= read -r line; do
        if [[ -n "$line_callback" ]]; then
          "$line_callback" "$repo_id" "$filename" "$line"
        else
          echo "$line"
        fi
      done < <(sed -n "$(( line_no + 1 )),$(( total_lines ))p" "$out_file")
      line_no="$total_lines"
    fi
    if [[ -n "$heartbeat_callback" ]]; then
      "$heartbeat_callback" "$repo_id" "$filename" "$elapsed"
    fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
  done
  wait "$hf_pid"
  local rc=$?
  set -e

  local total_lines
  total_lines="$(wc -l <"$out_file" | tr -d ' ')"
  if (( total_lines > line_no )); then
    while IFS= read -r line; do
      if [[ -n "$line_callback" ]]; then
        "$line_callback" "$repo_id" "$filename" "$line"
      else
        echo "$line"
      fi
    done < <(sed -n "$(( line_no + 1 )),$(( total_lines ))p" "$out_file")
  fi

  if (( rc != 0 )); then
    log_ts "HF download failed for $(basename "$filename")"
    rm -f "$out_file"
    return 1
  fi

  local downloaded_path
  downloaded_path="$(tail -n 1 "$out_file")"
  rm -f "$out_file"
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

  log_ts "HF download output path not found for $(basename "$filename")"
  return 1
}
