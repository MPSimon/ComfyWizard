SHELL := /bin/bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make run        Run the interactive wizard"
	@echo "  make sync       Run sync with args, e.g.: make sync STACK=wan WORKFLOW=godmode_v2_5"
	@echo "  make lint       Placeholder for linting"

.PHONY: lint
lint:
	@echo "No lint configured. Consider shellcheck for scripts."

.PHONY: run
run:
	@bash bin/wizard.sh

.PHONY: sync
sync:
	@if [[ -z "$$STACK" || -z "$$WORKFLOW" ]]; then \
	  echo "Usage: make sync STACK=wan WORKFLOW=godmode_v2_5 [OPTIONAL='path1 path2']"; \
	  exit 1; \
	fi
	@args=(); \
	for opt in $$OPTIONAL; do args+=("--optional" "$$opt"); done; \
	bash bin/sync.sh --stack "$$STACK" --workflow "$$WORKFLOW" "$${args[@]}"
