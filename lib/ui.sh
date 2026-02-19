#!/usr/bin/env bash
set -Eeuo pipefail

ui_msgbox() {
  local title="$1"
  local msg="$2"
  printf "%s: %b\n" "$title" "$msg" >&2
  if [[ -t 0 && -r /dev/tty ]]; then
    read -r -p "Press Enter to continue..." _ </dev/tty
  else
    read -r -p "Press Enter to continue..." _
  fi
  echo "" >&2
}

ui_yesno() {
  local title="$1"
  local msg="$2"
  printf "%s: %b\n" "$title" "$msg" >&2
  if [[ -t 0 && -r /dev/tty ]]; then
    read -r -p "Confirm? [y/N]: " ans </dev/tty
  else
    read -r -p "Confirm? [y/N]: " ans
  fi
  echo "" >&2
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

ui_menu() {
  local title="$1"
  local msg="$2"
  shift 2
  local options=("$@");

  echo "${title}: ${msg}" >&2
  local i=1
  local choices=()
  local labels=()
  while (( i <= ${#options[@]} )); do
    choices+=("${options[$((i-1))]}")
    labels+=("${options[$i]}")
    i=$(( i + 2 ))
  done
  local idx
  local opt
  while true; do
    for idx in "${!labels[@]}"; do
      echo "$(( idx + 1 ))) ${labels[$idx]}" >&2
    done
    if [[ -t 0 && -r /dev/tty ]]; then
      read -r -p "#? " REPLY </dev/tty
    else
      read -r -p "#? " REPLY
    fi
    echo "" >&2
    if [[ -z "${REPLY:-}" ]]; then
      echo ""
      return 1
    fi
    if ! [[ "$REPLY" =~ ^[0-9]+$ ]]; then
      echo "Invalid selection." >&2
      continue
    fi
    idx=$(( REPLY - 1 ))
    if (( idx < 0 || idx >= ${#choices[@]} )); then
      echo "Invalid selection." >&2
      continue
    fi
    echo "${choices[$idx]}"
    return 0
  done
}

ui_checklist() {
  local title="$1"
  local msg="$2"
  shift 2
  local options=("$@");

  echo "${title}: ${msg}" >&2
  local i=1
  local choices=()
  local labels=()
  while (( i <= ${#options[@]} )); do
    choices+=("${options[$((i-1))]}")
    labels+=("${options[$i]}")
    echo "$(( (i+2)/3 )). ${options[$i]}" >&2
    i=$(( i + 3 ))
  done
  if [[ -t 0 && -r /dev/tty ]]; then
    read -r -p "Select comma-separated numbers (or empty): " sel </dev/tty
  else
    read -r -p "Select comma-separated numbers (or empty): " sel
  fi
  echo "" >&2
  if [[ -z "$sel" ]]; then
    echo ""
    return 0
  fi
  local out=()
  IFS=',' read -r -a picks <<< "$sel"
  for p in "${picks[@]}"; do
    p="${p// /}"
    if [[ -n "$p" ]]; then
      if [[ "$p" =~ ^[0-9]+$ ]]; then
        local idx=$(( p - 1 ))
        if (( idx >= 0 && idx < ${#choices[@]} )); then
          out+=("${choices[$idx]}")
        fi
      fi
    fi
  done
  printf '%s\n' "${out[@]}"
}
