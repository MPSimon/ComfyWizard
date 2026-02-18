#!/usr/bin/env python3
import json
import os
from pathlib import Path

BASE = Path("/srv/comfy/stacks")


def list_files(p: Path):
    if not p.exists():
        return []
    return sorted(
        [
            f.name
            for f in p.iterdir()
            if f.is_file() and not f.name.startswith(".") and f.name != ".keep"
        ]
    )


def read_defaults(p: Path):
    if not p.exists():
        return {}
    try:
        with p.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def main():
    stacks = {}
    if BASE.exists():
        for stack_dir in sorted([d for d in BASE.iterdir() if d.is_dir()]):
            stack = stack_dir.name
            workflows = [f"workflows/{name}" for name in list_files(stack_dir / "workflows") if name.endswith(".json")]
            lora_char = [f"lora_character/{name}" for name in list_files(stack_dir / "lora_character")]
            lora_enh = [f"lora_enhancements/{name}" for name in list_files(stack_dir / "lora_enhancements")]
            upscale = [f"upscale_models/{name}" for name in list_files(stack_dir / "upscale_models")]
            defaults = read_defaults(stack_dir / "defaults.json")
            workflow_requirements = read_defaults(stack_dir / "workflow_requirements.json")
            stacks[stack] = {
                "workflows": workflows,
                "lora_character": lora_char,
                "lora_enhancements": lora_enh,
                "upscale_models": upscale,
                "defaults": defaults.get("defaults", {}),
                "workflow_requirements": workflow_requirements.get("workflow_requirements", {}),
            }

    print("Content-Type: application/json\n")
    print(json.dumps({"stacks": stacks}))


if __name__ == "__main__":
    main()
