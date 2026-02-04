#!/usr/bin/env bash
set -Eeuo pipefail

DEST=/tmp/ComfyWizard
TAR=/tmp/ComfyWizard.tar.gz

if [[ -z "${ARTIFACT_AUTH:-}" ]]; then
  echo "ARTIFACT_AUTH is required. Set it via RunPod Secrets (e.g., Basic <base64(user:pass)>)." >&2
  exit 1
fi

curl -L https://github.com/MPSimon/ComfyWizard/archive/refs/heads/main.tar.gz -o "$TAR"
mkdir -p "$DEST"
tar -xzf "$TAR" -C "$DEST" --strip-components=1

bash "$DEST/bin/wizard.sh"
