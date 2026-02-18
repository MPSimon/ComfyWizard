#!/usr/bin/env bash
set -Eeuo pipefail

DEST=/tmp/ComfyWizard
TAR=/tmp/ComfyWizard.tar.gz
REPO_TAR_URL=https://github.com/MPSimon/ComfyWizard/archive/refs/heads/main.tar.gz

if [[ -z "${ARTIFACT_AUTH:-}" ]]; then
  echo "ARTIFACT_AUTH is required. Set it via RunPod Secrets (e.g., Basic <base64(user:pass)>)." >&2
  exit 1
fi

curl -fsSL "$REPO_TAR_URL" -o "$TAR"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TAR" -C "$DEST" --strip-components=1

required_paths=(
  "lib/json.sh"
  "lib/fs.sh"
  "lib/ui.sh"
  "config/config.json"
  "bin/sync.sh"
)

missing_paths=()
for rel in "${required_paths[@]}"; do
  if [[ ! -f "$DEST/$rel" ]]; then
    missing_paths+=("$rel")
  fi
done

if (( ${#missing_paths[@]} > 0 )); then
  echo "ComfyWizard bootstrap failed. Missing required files after extraction:" >&2
  for rel in "${missing_paths[@]}"; do
    echo " - $rel" >&2
  done
  exit 1
fi

bash "$DEST/bin/wizard.sh"
