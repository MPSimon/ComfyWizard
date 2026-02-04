#!/usr/bin/env bash
set -Eeuo pipefail

DEST=/tmp/ComfyWizard
TAR=/tmp/ComfyWizard.tar.gz

curl -L https://github.com/MPSimon/ComfyWizard/archive/refs/heads/main.tar.gz -o "$TAR"
mkdir -p "$DEST"
tar -xzf "$TAR" -C "$DEST" --strip-components=1

bash "$DEST/bin/wizard.sh"
