# ComfyWizard

Small wizard + downloader for **private** ComfyUI assets per stack (WAN first, QWEN later).

## What this is
- A terminal wizard that lets you choose a stack and workflow.
- Downloads **private** assets (character LoRAs, optional LoRAs, private workflows) from your Hetzner HTTPS host.
- Activates the chosen workflow by copying it into ComfyUI's workflows and `Active` folders.

## Responsibilities split (important)
- `start.sh` (WAN repo) does **all** baseline setup:
  - Install ComfyUI and custom nodes
  - Download **public** baseline models (WAN checkpoints, VAEs, encoders, public LoRAs, detection, etc.)
  - Start and healthcheck ComfyUI
- This project does **only** private assets:
  - Download private LoRAs/workflows
  - Activate workflow JSON

This wizard **does not** install or start ComfyUI.

## Expected server structure
Private assets are served over HTTPS like:

`https://<host>/stacks/<stack>/...`

Example for WAN:

`https://comfy.bitreq.nl/stacks/wan/lora_character/...`
`https://comfy.bitreq.nl/stacks/wan/workflows/...`

## Current flow (visual)
🟢 RunPod (WAN repo, clean)
➡️ 📦 downloads ComfyWizard
➡️ 🧙 ComfyWizard fetches `https://comfy.bitreq.nl/manifest`
➡️ ✅ you select workflow + files
➡️ ⬇️ downloads only chosen files
➡️ 💾 places files into ComfyUI folders

## Auth (planned/active)
🔐 Set a RunPod secret and export it as `ARTIFACT_AUTH`.
Example:
`ARTIFACT_AUTH="Basic <base64(user:pass)>"`
This header is used for both `/manifest` and `/stacks/*`.

### RunPod setup (short)
1. Create a secret in RunPod (Account -> Secrets).
   - URL: https://console.runpod.io/user/secrets/create
2. In your template/env, set:
   `ARTIFACT_AUTH={{ RUNPOD_SECRET_secret_name }}`
3. Launch the pod. The wizard will read `ARTIFACT_AUTH` automatically.

Docs: [RunPod secrets](https://docs.runpod.io/pods/templates/secrets)

## How to run
Interactive wizard:

```bash
bash bin/wizard.sh
```

Non-interactive:

```bash
bash bin/sync.sh --stack wan --workflow Wan_Animate_God_Mode_V2.5_HearmemanAI
```

## Configuration
Global config: `config/config.json`
- `artifact_host` defaults to `https://comfy.bitreq.nl`
- `stacks_base_path` defaults to `/stacks`
- `comfy_root_candidates` defaults to `/workspace/ComfyUI`, `/ComfyUI`

Remote manifest (source of truth):
- `https://comfy.bitreq.nl/manifest` (generated on the server at request time)
- The manifest is created by `server/manifest.py` on the Hetzner server and scans `/srv/comfy/stacks`.

Per-stack defaults (server):
- `stacks/<stack>/defaults.json` (required/optional defaults per workflow)

Routing rules (download targets in ComfyUI):
- `workflows/*` -> `user/default/workflows/` and `user/default/workflows/Active/`
- `lora_character/*`, `lora_enhancements/*` -> `models/loras/`
- `upscale_models/*` -> `models/upscale_models/` (for UpscaleModelLoader `.pth`)

## How to add a new workflow
1. Upload the workflow JSON to `stacks/<stack>/workflows/` on the server.
2. (Optional) Add default required/optional files in `stacks/<stack>/defaults.json` on the server.

## How to add a new private LoRA or artifact
1. Upload the file to `stacks/<stack>/lora_character`, `stacks/<stack>/lora_enhancements`, or `stacks/<stack>/upscale_models` on the server.
2. (Optional) Add default required/optional files in `stacks/<stack>/defaults.json` on the server.

## RunPod launcher (one file)
Copy this file or run it on a clean RunPod instance:

`bin/runpod-launch.sh`
