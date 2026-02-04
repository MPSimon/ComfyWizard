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

Per-stack config:
- `config/stacks/<stack>/manifest.json` (defaults only)
- `config/stacks/<stack>/workflows/` (workflow file names only; files are gitignored)
- `config/stacks/<stack>/lora_character/`
- `config/stacks/<stack>/lora_enhancements/`
- `config/stacks/<stack>/artifacts/`

## How to add a new workflow
1. Upload the workflow JSON to `stacks/<stack>/workflows/` on the server.
2. Create an empty placeholder file with the same name in `config/stacks/<stack>/workflows/`.
   - These placeholder files are gitignored to prevent accidental commits.
3. (Optional) Add default required/optional files in `config/stacks/<stack>/manifest.json`.

## How to add a new private LoRA or artifact
1. Upload the file to `stacks/<stack>/lora_character`, `stacks/<stack>/lora_enhancements`, or `stacks/<stack>/artifacts` on the server.
2. Create an empty placeholder file with the same name under the matching local folder in `config/stacks/<stack>/`.
   - These placeholder files are gitignored to prevent accidental commits.
3. (Optional) Add default required/optional files in `config/stacks/<stack>/manifest.json`.
