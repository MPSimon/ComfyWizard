# ComfyWizard

Small wizard + downloader for ComfyUI assets per stack (WAN first, QWEN later).

## What this is
- A terminal wizard that lets you choose a stack and workflow.
- Downloads private assets (character LoRAs, optional LoRAs, workflow JSON) from your Hetzner HTTPS host.
- Resolves workflow-level Hugging Face requirements and downloads missing model files with `hf download`.
- Activates the chosen workflow by copying it into ComfyUI's workflows and `Active` folders.

## Responsibilities split (important)
- `start.sh` (WAN repo or base image pipeline) does baseline setup:
  - Install ComfyUI and custom nodes
  - Optionally pre-bake shared public baseline models
  - Start and healthcheck ComfyUI
- This project does workflow-time sync:
  - Download private LoRAs/workflows from Hetzner
  - Download missing per-workflow HF requirements
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
➡️ 🔎 preflight checks local HF requirements
➡️ ⬇️ downloads missing HF files + selected private files
➡️ 💾 places files into ComfyUI folders and activates workflow JSON

If you choose `None (skip workflow)`, no workflow JSON is downloaded or activated and defaults are skipped. Optional downloads still work.

## Auth (planned/active)
🔐 Set a RunPod secret and export it as `ARTIFACT_AUTH`.
Example:
`ARTIFACT_AUTH="Basic <base64(user:pass)>"`
This header is used for both `/manifest` and `/stacks/*`.

### RunPod setup (short)
1. Create a secret in RunPod (Account -> Secrets).
   - URL: https://console.runpod.io/user/secrets/create
2. In your template/env, set:
   `ARTIFACT_AUTH={{ RUNPOD_SECRET_artifact_auth }}`
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

Optional-only (no workflow):

```bash
bash bin/sync.sh --stack wan --optional lora_enhancements/HMFemme_V1.safetensors
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
- `stacks/<stack>/defaults.json` (required/optional private file defaults per workflow)

Per-workflow Hugging Face requirements (in manifest):
- `stacks.<stack>.workflow_requirements.<workflow_json>.required[]`
- `stacks.<stack>.workflow_requirements.<workflow_json>.optional[]`
- On server these are sourced from `stacks/<stack>/workflow_requirements.json`.

Requirement item shape:

```json
{
  "source": "huggingface",
  "repo_id": "org/model-repo",
  "filename": "path/in/repo/model.safetensors",
  "target_rel_dir": "checkpoints",
  "revision": "main",
  "expected_sha256": "optional lowercase hex"
}
```

Routing rules (download targets in ComfyUI):
- `workflows/*` -> `user/default/workflows/` and `user/default/workflows/Active/`
- `lora_character/*`, `lora_enhancements/*` -> `models/loras/`
- `upscale_models/*` -> `models/upscale_models/` (for UpscaleModelLoader `.pth`)
- HF requirements -> `models/<target_rel_dir>/<basename(filename)>`

HF failure behavior:
- If a required HF asset fails, sync continues with remaining HF/private downloads.
- Workflow JSON activation still happens when workflow download succeeds.
- The command exits non-zero (`2`) and prints a final required-failure summary.

## How to add a new workflow
1. Upload the workflow JSON to `stacks/<stack>/workflows/` on the server.
2. (Optional) Add default required/optional files in `stacks/<stack>/defaults.json` on the server.

## How to add a new private LoRA or artifact
1. Upload the file to `stacks/<stack>/lora_character`, `stacks/<stack>/lora_enhancements`, or `stacks/<stack>/upscale_models` on the server.
2. (Optional) Add default required/optional files in `stacks/<stack>/defaults.json` on the server.

## RunPod launcher (one file)
Copy this file or run it on a clean RunPod instance:

`bin/runpod-launch.sh`

## Manual verification checklist
1. Preflight summary in wizard:
   - Run `bash bin/wizard.sh`
   - Select a workflow with `workflow_requirements`
   - Confirm the summary line `HF required: <total> (present: <n>, to download: <n>)`
2. Required HF success path:
   - Run `bash bin/sync.sh --stack <stack> --workflow <workflow>`
   - Verify missing required HF files are downloaded into `models/<target_rel_dir>/`
3. Required HF failure continuation:
   - Add one invalid `repo_id` or `filename` requirement
   - Verify other downloads continue
   - Verify workflow JSON is copied to `.../workflows/Active/`
   - Verify final summary lists exact failed required HF entries and exit code is `2`
