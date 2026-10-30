.PHONY: help build local-images up down restart logs ps shell chat tui console model webui gtw-dashboard status fix-permissions clean destroy setup-dirs profile-list profile-create profile-use bot-setup bot-start bot-logs desktop-status desktop-start desktop-stop sync-from-host sync-to-host doctor-fix setup-keys update-image \
	omniroute-browser-build omniroute-key free-combos free-combo-test tool-call-check provider-free dashboard-logs hindsight-install hindsight-llm-check hindsight-config hindsight-enable hindsight-disable hindsight-status hindsight-health hindsight-logs hindsight-ui hindsight-banks hindsight-shell \
	provider-omniroute provider-direct provider-show omniroute-models gtw-logs \
	verify demo-memory \
	langfuse-up langfuse-down langfuse-logs langfuse-ui langfuse-status langfuse-traces \
	langfuse-otel-header langfuse-secrets langfuse-reset langfuse-verify \
	webhook-up webhook-down webhook-logs webhook-test webhook-log

# Load .env if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# Default variables
CONTAINER_NAME ?= hermes-agent
DATA_DIR ?= ./data
WORKSPACE_DIR ?= ./workspace
HOST_HERMES_DIR ?= $(HOME)/.hermes
HERMES_UID ?= $(shell id -u)
HERMES_GID ?= $(shell id -g)

export HERMES_UID
export HERMES_GID
export DATA_DIR
export WORKSPACE_DIR
export CONTAINER_NAME

# Locally DERIVED images. Each is built from a Dockerfile in docker/ by its own
# target and exists nowhere but this machine -- no registry serves them.
HINDSIGHT_PATCHED_IMAGE = $(or $(HINDSIGHT_PATCHED_TAG),hindsight-patched:local)
OMNIROUTE_BROWSER_IMAGE = $(or $(OMNIROUTE_BROWSER_TAG),omniroute-browser:local)

help: ## Show this help message
	@echo "Available commands for Hermes Agent Docker setup:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup-dirs: ## Create local data and workspace directories with correct permissions
	@mkdir -p $(DATA_DIR) $(WORKSPACE_DIR) $(or $(OMNIROUTE_DATA_DIR),./data-gtw) $(DATA_DIR)/hindsight
	@case "$(HINDSIGHT_DATA_VOLUME)" in ./*|/*) mkdir -p "$(HINDSIGHT_DATA_VOLUME)" ;; esac
	@chmod -R 775 $(DATA_DIR) $(WORKSPACE_DIR) 2>/dev/null || true
	@# The chmod -R above also hits the gateway's control files, and Hermes
	@# REFUSES any control path carrying group/other bits -- the check is
	@# `mode & 0o077` must be 0 (hermes_cli/gateway_runtime_discovery.py), so
	@# 0775 fails it just as 0755 does:
	@#   gateway inaccessible: unsafe_control_permissions
	@#   /opt/data/gateway.sock has mode 0755, expected 0600
	@# Re-tighten them so `make up` cannot leave the gateway undiscoverable.
	@# gateway.sock is expected to fail here: chmod() on a SOCKET returns EINVAL
	@# on a Docker Desktop VirtioFS ("fakeowner") bind mount, which is a separate
	@# problem the socket cannot be repaired out of -- see docs note.
	@for f in gateway.lock gateway.pid gateway.sock gateway.sock.path; do \
		if [ -e "$(DATA_DIR)/$$f" ]; then chmod 600 "$(DATA_DIR)/$$f" 2>/dev/null || true; fi; \
	done
	@if [ ! -f .env ]; then cp .env.example .env; echo "Created .env from .env.example"; fi
	@echo "Directories ready: $(DATA_DIR) (Hermes /opt/data), $(WORKSPACE_DIR) (/workspace), $(or $(OMNIROUTE_DATA_DIR),./data-gtw) (OmniRoute gtw)"
	@echo "Hindsight PostgreSQL storage: $(or $(HINDSIGHT_DATA_VOLUME),hindsight-pgdata) (named volume unless it starts with ./ or /)"

local-images: ## Build whichever locally derived images .env selects and the daemon is missing
	@# Only `hermes` has a `build:` stanza in docker-compose.yml, so compose can
	@# rebuild just that one on its own. `hindsight` and `omniroute` are declared
	@# with `image:` alone: normally the upstream image is PULLED, and .env can
	@# instead point them at a local derivative built from docker/Dockerfile.*.
	@# Nothing can pull those tags, so a missing one aborts the whole `up` with
	@#   Error response from daemon: pull access denied for omniroute-browser,
	@#   repository does not exist or may require 'docker login'
	@# (and the same for hindsight-patched, which .env.example selects by
	@# default). Build them here, before compose ever goes looking.
	@if [ "$(or $(HINDSIGHT_IMAGE),):$(or $(HINDSIGHT_VERSION),)" = "$(HINDSIGHT_PATCHED_IMAGE)" ] && \
		! docker image inspect $(HINDSIGHT_PATCHED_IMAGE) >/dev/null 2>&1; then \
		echo "==> .env selects $(HINDSIGHT_PATCHED_IMAGE) but it is not built; building it now"; \
		$(MAKE) --no-print-directory hindsight-patched-build; \
	fi
	@if [ "$(or $(OMNIROUTE_IMAGE),)" = "$(OMNIROUTE_BROWSER_IMAGE)" ] && \
		! docker image inspect $(OMNIROUTE_BROWSER_IMAGE) >/dev/null 2>&1; then \
		echo "==> .env selects $(OMNIROUTE_BROWSER_IMAGE) but it is not built; building it now"; \
		$(MAKE) --no-print-directory omniroute-browser-build; \
	fi

build: setup-dirs local-images ## Build the Hermes Docker image
	docker compose build

up: setup-dirs local-images ## Start Hermes Agent container in background
	docker compose up -d
	@# The hermes-installs named volume must be writable by uid 1000. New images
	@# seed this correctly, but a volume created by an older image is root-owned.
	@docker exec $(CONTAINER_NAME) chown 1000:1000 /opt/data/installs 2>/dev/null || true
	@docker exec $(CONTAINER_NAME) chmod 777 /opt/data/installs 2>/dev/null || true

down: ## Stop and remove the Hermes Agent container
	docker compose down

restart: down up ## Restart the Hermes container

update-image: setup-dirs local-images ## Pull the latest upstream rebuilt Docker image and restart container
	@# --ignore-pull-failures: the locally derived tags (hindsight-patched:local,
	@# omniroute-browser:local) have no registry, so pulling them always fails.
	@# local-images above has already made sure they exist.
	docker compose pull --ignore-pull-failures
	docker compose up -d --force-recreate

logs: ## Tail the Hermes agent logs (gateway + supervised dashboard)
	@# "hermes" is the compose SERVICE name. Passing $(CONTAINER_NAME)
	@# (hermes-agent) here fails with "no such service".
	docker compose logs -f hermes

dashboard-logs: ## Tail only the supervised dashboard lines from the Hermes container
	@docker compose logs hermes | grep -i dashboard | tail -20
	@echo ""
	@echo "Expect: 'service dashboard successfully started' and 'HERMES_DASHBOARD_READY port=9119'"

ps: ## Check container status
	docker compose ps

status: ps ## Check Hermes doctor status inside the container
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@docker exec -it $(CONTAINER_NAME) hermes doctor || true

fix-permissions: ## Fix socket, data and plugin-install permissions for macOS/Docker bind mount
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@chmod 755 "$(DATA_DIR)" "$(WORKSPACE_DIR)" 2>/dev/null || true
	@docker exec $(CONTAINER_NAME) chown 1000:1000 /opt/data/installs 2>/dev/null || true
	@docker exec $(CONTAINER_NAME) chmod 777 /opt/data/installs 2>/dev/null || true
	@echo "Permissions adjusted for $(DATA_DIR) and the hermes-installs volume."

doctor-fix: ## Run hermes doctor --fix inside the container to auto-resolve issues
	@docker exec -it $(CONTAINER_NAME) hermes doctor --fix || true

setup-keys: ## Run interactive 'hermes setup' to configure LLM providers and missing API keys
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@docker exec -it $(CONTAINER_NAME) hermes setup

shell: ## Open an interactive bash shell inside the container
	@docker exec -it $(CONTAINER_NAME) bash

chat: ## Run an interactive Hermes CLI chat session inside the container (classic CLI)
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@docker exec -it $(CONTAINER_NAME) hermes chat --cli

tui: ## Run the rich Ink TUI interface inside the container
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@docker exec -it $(CONTAINER_NAME) hermes --tui

console: ## Open the safe Hermes administrative command console inside the container
	@docker exec -it $(CONTAINER_NAME) hermes console

model: ## Interactive model and provider selector inside the container
	@docker exec -it $(CONTAINER_NAME) hermes model

webui: ## Open Hermes Web UI dashboard in the default browser (http://localhost:9119)
	@echo "Opening Hermes Web UI at http://localhost:$(or $(DASHBOARD_PORT),9119)..."
	@open http://localhost:$(or $(DASHBOARD_PORT),9119) 2>/dev/null || xdg-open http://localhost:$(or $(DASHBOARD_PORT),9119) 2>/dev/null || echo "Navigate to http://localhost:$(or $(DASHBOARD_PORT),9119)"

gtw-dashboard: ## Open OmniRoute AI Gateway Web Dashboard (http://localhost:20128)
	@echo "Opening OmniRoute Dashboard at http://localhost:$(or $(OMNIROUTE_PORT),20128)..."
	@open http://localhost:$(or $(OMNIROUTE_PORT),20128) 2>/dev/null || xdg-open http://localhost:$(or $(OMNIROUTE_PORT),20128) 2>/dev/null || echo "Navigate to http://localhost:$(or $(OMNIROUTE_PORT),20128)"

clean: ## Stop container and clean temporary container artifacts (keeps data directory)
	docker compose down --remove-orphans -v

destroy: ## Complete teardown: stops container, removes images and clears data directory
	@echo "WARNING: This will permanently delete $(DATA_DIR) and container state."
	@read -p "Are you sure? [y/N]: " confirm && [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ] || (echo "Aborted." && exit 1)
	docker compose down -v --rmi all --remove-orphans
	rm -rf $(DATA_DIR) $(WORKSPACE_DIR)
	@echo "Hermes container and data destroyed."

# ==============================================================================
# Profile Management
# ==============================================================================

profile-list: ## List all profiles configured in the Hermes container
	@docker exec -it $(CONTAINER_NAME) hermes profile list

profile-create: ## Create a new profile (Usage: make profile-create NAME=myagent [CLONE=1])
	@if [ -z "$(NAME)" ]; then echo "Error: Specify NAME=profilename (e.g., make profile-create NAME=coder)"; exit 1; fi
	@if [ "$(CLONE)" = "1" ]; then \
		docker exec -it $(CONTAINER_NAME) hermes profile create $(NAME) --clone; \
		docker exec -it $(CONTAINER_NAME) hermes -p $(NAME) config unset TELEGRAM_BOT_TOKEN 2>/dev/null || true; \
		docker exec -it $(CONTAINER_NAME) hermes -p $(NAME) config unset API_SERVER_ENABLED 2>/dev/null || true; \
		echo "Cleaned duplicate TELEGRAM_BOT_TOKEN / API_SERVER_ENABLED from clone to avoid gateway collision."; \
	else \
		docker exec -it $(CONTAINER_NAME) hermes profile create $(NAME); \
	fi
	@echo "Profile $(NAME) created."

profile-use: ## Switch the default profile in the container (Usage: make profile-use NAME=myagent)
	@if [ -z "$(NAME)" ]; then echo "Error: Specify NAME=profilename"; exit 1; fi
	@docker exec -it $(CONTAINER_NAME) hermes profile use $(NAME)

# ==============================================================================
# Bot & Gateway Operations
# ==============================================================================

bot-setup: ## Run interactive messaging gateway setup (Telegram, Discord, Slack, etc.)
	@docker exec -it $(CONTAINER_NAME) hermes gateway setup

bot-start: ## Start or restart gateway inside the container
	@docker exec -it $(CONTAINER_NAME) hermes gateway restart || docker exec -it $(CONTAINER_NAME) hermes gateway start

bot-logs: ## View messaging gateway logs
	@docker exec -it $(CONTAINER_NAME) hermes logs gateway -f

# ==============================================================================
# Bot Desktop — the headless Xfce "Screen" the agent (and a human) can drive
#
# The X stack is baked into the image by docker/Dockerfile; `make build` is what
# installs it. There is NO VNC port to publish: Xvnc listens on a 0600 unix
# socket only (-rfbport -1) at $(DATA_DIR)/bot-desktop/rfb.sock, and the
# dashboard on :$(DASHBOARD_PORT) bridges it to the browser over a WebSocket.
# Open it from the Screen pane in `make webui`.
#
# These targets go through the `hermes` shim, which drops to uid 1000 before
# exec'ing — important here: a screen started as root would leave an rfb.sock
# the dashboard (uid 1000) cannot open.
# ==============================================================================

desktop-status: ## Show whether this profile's Bot Desktop is installed and running
	@docker exec -it $(CONTAINER_NAME) hermes computer-use screen status

desktop-start: ## Start this profile's Bot Desktop (then view it in the dashboard's Screen pane)
	@docker exec -it $(CONTAINER_NAME) hermes computer-use screen start

desktop-stop: ## Stop this profile's Bot Desktop and free its ~220 MiB
	@docker exec -it $(CONTAINER_NAME) hermes computer-use screen stop

# ==============================================================================
# Local ~/.hermes <-> Container Data Synchronization
# ==============================================================================

sync-from-host: setup-dirs ## Copy local ~/.hermes files to container data directory (./data)
	@echo "Copying $(HOST_HERMES_DIR) to $(DATA_DIR)..."
	@if [ -d "$(HOST_HERMES_DIR)" ]; then \
		rsync -av --progress $(HOST_HERMES_DIR)/ $(DATA_DIR)/; \
		echo "Sync complete."; \
	else \
		echo "Source $(HOST_HERMES_DIR) does not exist."; exit 1; \
	fi

sync-to-host: ## Copy container data (./data) back to host ~/.hermes (creates backup first)
	@echo "Backing up $(HOST_HERMES_DIR) to $(HOST_HERMES_DIR).bak..."
	@if [ -d "$(HOST_HERMES_DIR)" ]; then cp -r $(HOST_HERMES_DIR) $(HOST_HERMES_DIR).bak-$$(date +%Y%m%d%H%M%S); fi
	@echo "Copying $(DATA_DIR) to $(HOST_HERMES_DIR)..."
	@rsync -av --progress $(DATA_DIR)/ $(HOST_HERMES_DIR)/
	@echo "Sync complete."

# ==============================================================================
# Hindsight Long-Term Memory
#
# The plugin lives in ./data/plugins (bind-mounted to $HERMES_HOME/plugins), so
# it is installed ONCE and survives down/up/--force-recreate and image rebuilds.
# Its Python dependency environments live in the hermes-installs named volume,
# which is required: the macOS bind mount is case-insensitive and the Python
# toolchain Hermes copies contains both share/terminfo/a and share/terminfo/A.
# ==============================================================================


# On macOS the bind mount (virtiofs) creates gateway.sock as 0755 but Hermes
# demands 0600. The gateway recreates the socket a few seconds AFTER
# `docker compose restart` returns, so a single chmod right after a restart
# races and loses. Every target that restarts hermes must poll instead.
define WAIT_SOCK
	@for i in $$(seq 1 40); do \
		if [ -e "$(DATA_DIR)/gateway.sock" ]; then \
			chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; \
			[ "$$(stat -f '%Lp' "$(DATA_DIR)/gateway.sock" 2>/dev/null)" = "600" ] && break; \
		fi; \
		sleep 2; \
	done
endef

HINDSIGHT_PLUGIN_SHA ?= d952b6e655fccab4581ee0722b51c5f103873d12
HINDSIGHT_API_PORT ?= 8888
HINDSIGHT_UI_PORT ?= 9999
HINDSIGHT_BANK_ID ?= hermes-course

hindsight-install: ## Install the pinned Hindsight memory plugin into the container (persists in ./data/plugins)
	@echo "Installing hindsight plugin pinned @ $(HINDSIGHT_PLUGIN_SHA)..."
	@docker exec $(CONTAINER_NAME) hermes plugins install hindsight \
		--ref $(HINDSIGHT_PLUGIN_SHA) --yes-deps --enable --force
	@docker exec $(CONTAINER_NAME) hermes plugins list | grep -i hindsight || true

hindsight-config: ## Regenerate ./data/hindsight/config.json from .env (backs up the old one)
	@DATA_DIR=$(DATA_DIR) ./docker/write-hindsight-config.sh

hindsight-enable: hindsight-config ## Activate Hindsight as the Hermes memory provider and restart the agent
	@docker exec $(CONTAINER_NAME) hermes config set memory.provider hindsight
	@docker compose restart hermes
	$(WAIT_SOCK)
	@echo "Hindsight enabled. Verify with: make hindsight-status"

hindsight-disable: ## Turn off the external memory provider (built-in MEMORY.md/USER.md stays active)
	@docker exec $(CONTAINER_NAME) hermes memory off || true
	@docker compose restart hermes
	$(WAIT_SOCK)
	@echo "External memory provider disabled; built-in memory still active."

hindsight-status: ## Show Hermes memory provider status (built-in + external provider)
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@docker exec $(CONTAINER_NAME) hermes memory status

hindsight-health: ## Probe the Hindsight API from inside the Hermes container (proves the network link)
	@echo "--- hindsight /health/ready as seen BY HERMES ---"
	@docker exec $(CONTAINER_NAME) curl -fsS http://hindsight:8888/health/ready && echo "" \
		|| echo "UNREACHABLE: check 'docker compose ps hindsight' and 'make hindsight-logs'"

hindsight-banks: ## List the memory banks stored in the Hindsight server
	@echo "--- GET http://hindsight:8888/v1/default/banks as seen BY HERMES ---"
	@docker exec $(CONTAINER_NAME) curl -fsS http://hindsight:8888/v1/default/banks || \
		echo "UNREACHABLE - check 'docker compose ps hindsight' and 'make hindsight-logs'"
	@echo ""
	@echo "(A bank appears only after the agent's first retain. Browse it: make hindsight-ui)"

hindsight-llm-check: ## Prove the Hindsight -> OmniRoute -> upstream LLM leg with a real call
	@echo "--- POST /v1/default/banks/$(HINDSIGHT_BANK_ID)/health/llm ---"
	@docker exec $(CONTAINER_NAME) curl -s -m 120 -X POST \
		http://hindsight:8888/v1/default/banks/$(HINDSIGHT_BANK_ID)/health/llm \
		| python3 -I -c 'import json,sys; \
raw=sys.stdin.read().strip(); \
d=json.loads(raw) if raw.startswith("{") else {}; \
ops=d.get("operations") or []; \
[print("  %-14s ok=%-5s %s (%.0f ms)" % (o.get("operation"),o.get("ok"),o.get("status"),o.get("latency_ms") or 0)) for o in ops] \
	or print("  unexpected response:",raw[:200]); \
st=set(o.get("status") for o in ops); \
print(); \
print("  connected    -> this leg works end to end.") if "connected" in st else None; \
print("  auth_failed  -> OmniRoute does not accept GTW_API_KEY. Run: make omniroute-key") if "auth_failed" in st else None; \
print("  timeout      -> the upstream answered too slowly for the ~10s probe budget.") if "timeout" in st else None; \
print("                  Normal on FREE keyless combos (browser-driven, 30-150s/call);") if "timeout" in st else None; \
print("                  it does NOT mean retain is broken - verify with a real retain.") if "timeout" in st else None'
	@echo ""

hindsight-patched-build: ## Build Hindsight with tolerant consolidation parsing (fixes the bare-list ValidationError)
	docker build -f docker/Dockerfile.hindsight -t $(HINDSIGHT_PATCHED_IMAGE) docker/
	@echo ""
	@echo "Built $(HINDSIGHT_PATCHED_IMAGE). Set in .env:"
	@echo "  HINDSIGHT_IMAGE=hindsight-patched"
	@echo "  HINDSIGHT_VERSION=local"
	@echo "Then: docker compose up -d hindsight && make hindsight-consolidate"

hindsight-unstick: ## Recover consolidation tasks orphaned by a stale worker lease (after a container recreate)
	@CONTAINER_NAME=$(CONTAINER_NAME) ./docker/hindsight-unstick.sh

hindsight-consolidate: ## Trigger a consolidation round and report created/updated plus schema errors
	@HINDSIGHT_BANK_ID=$(HINDSIGHT_BANK_ID) CONTAINER_NAME=$(CONTAINER_NAME) ./docker/hindsight-consolidate.sh

hindsight-roundtrip: ## Prove retain -> extract -> recall with a canary fact (model-independent)
	@HINDSIGHT_BANK_ID=$(HINDSIGHT_BANK_ID) CONTAINER_NAME=$(CONTAINER_NAME) ./docker/hindsight-roundtrip.sh

hindsight-logs: ## Tail the Hindsight memory server logs
	@docker compose logs -f hindsight

hindsight-shell: ## Open a shell inside the Hindsight server container
	@docker exec -it $(CONTAINER_NAME)-hindsight sh

hindsight-ui: ## Open the Hindsight memory explorer UI (knowledge graph browser)
	@echo "Opening Hindsight UI at http://localhost:$(HINDSIGHT_UI_PORT)..."
	@open http://localhost:$(HINDSIGHT_UI_PORT) 2>/dev/null || xdg-open http://localhost:$(HINDSIGHT_UI_PORT) 2>/dev/null || echo "Navigate to http://localhost:$(HINDSIGHT_UI_PORT)"

# ==============================================================================
# Inference Routing: OmniRoute vs direct provider
# ==============================================================================

provider-show: ## Show which inference provider and base_url Hermes is currently using
	@printf "model.provider : "; docker exec $(CONTAINER_NAME) hermes config get model.provider 2>/dev/null || echo "(unset)"
	@printf "model.base_url : "; docker exec $(CONTAINER_NAME) hermes config get model.base_url 2>/dev/null || echo "(unset)"
	@printf "model.default  : "; docker exec $(CONTAINER_NAME) hermes config get model.default 2>/dev/null || echo "(unset)"

provider-omniroute: ## Route Hermes inference through the OmniRoute gateway
	@docker exec $(CONTAINER_NAME) hermes config set model.provider custom
	@docker exec $(CONTAINER_NAME) hermes config set model.base_url http://omniroute:20128/v1
	@docker compose restart hermes
	$(WAIT_SOCK)
	@echo "Hermes now routes inference via OmniRoute (bearer token = GTW_API_KEY)."
	@echo "Pick a model OmniRoute actually serves: make model   (or: make omniroute-models)"

provider-direct: ## Route Hermes inference straight at OpenRouter, bypassing OmniRoute
	@docker exec $(CONTAINER_NAME) hermes config set model.provider openrouter
	@docker exec $(CONTAINER_NAME) hermes config set model.base_url https://openrouter.ai/api/v1
	@docker compose restart hermes
	$(WAIT_SOCK)
	@echo "Hermes now calls OpenRouter directly (needs OPENROUTER_API_KEY in ./data/.env)."

omniroute-models: ## List the models OmniRoute advertises, queried from inside the Hermes container
	@echo "--- GET http://omniroute:20128/v1/models as seen BY HERMES ---"
	@code=$$(docker exec $(CONTAINER_NAME) curl -s -o /tmp/gtwmodels -w '%{http_code}' \
		-H "Authorization: Bearer $(or $(GTW_API_KEY),omniroute-local)" \
		http://omniroute:20128/v1/models); \
	echo "HTTP $$code"; \
	docker exec $(CONTAINER_NAME) head -c 600 /tmp/gtwmodels 2>/dev/null; echo ""; \
	if [ "$$code" = "401" ]; then \
		echo ""; \
		echo "401 = OmniRoute does not recognise GTW_API_KEY ('$(or $(GTW_API_KEY),omniroute-local)')."; \
		echo "OmniRoute requires a key that exists in ITS OWN database, even when"; \
		echo "OMNIROUTE_REQUIRE_API_KEY=false. The default value is a placeholder."; \
		echo "  1) make gtw-dashboard         (password: $(or $(OMNIROUTE_INITIAL_PASSWORD),omniroute-admin))"; \
		echo "  2) connect at least one upstream provider"; \
		echo "  3) Dashboard -> Endpoints -> create a key, copy it"; \
		echo "  4) put it in .env as GTW_API_KEY=... then: make restart"; \
	elif [ "$$code" = "000" ]; then \
		echo "No response - is the omniroute service up? (docker compose ps)"; \
	fi

gtw-logs: ## Tail the OmniRoute gateway logs
	@docker compose logs -f omniroute

# ==============================================================================
# Verification & Demos
# ==============================================================================

verify: ## Walk the whole stack and report what is actually wired up
	@echo "=============================================================="
	@echo " 1. Container status"
	@echo "=============================================================="
	@docker compose ps
	@echo ""
	@echo "=============================================================="
	@echo " 2. OmniRoute reachable from Hermes?"
	@echo "=============================================================="
	@$(MAKE) --no-print-directory omniroute-models
	@echo "=============================================================="
	@echo " 3. Hindsight reachable from Hermes?"
	@echo "=============================================================="
	@$(MAKE) --no-print-directory hindsight-health
	@echo "=============================================================="
	@echo " 4. Hermes inference routing"
	@echo "=============================================================="
	@$(MAKE) --no-print-directory provider-show
	@echo ""
	@echo "=============================================================="
	@echo " 5. Hindsight plugin installed & enabled?"
	@echo "=============================================================="
	@docker exec $(CONTAINER_NAME) hermes plugins list | grep -i hindsight || echo "NOT INSTALLED - run: make hindsight-install"
	@echo ""
	@echo "=============================================================="
	@echo " 6. Hermes memory provider"
	@echo "=============================================================="
	@$(MAKE) --no-print-directory hindsight-status
	@echo ""
	@echo "=============================================================="
	@echo " 7. Hindsight memory banks"
	@echo "=============================================================="
	@$(MAKE) --no-print-directory hindsight-banks
	@echo ""
	@echo "=============================================================="
	@echo " 8. Hermes doctor"
	@echo "=============================================================="
	@# No -it here: verify must work in a pipe or CI, where there is no TTY.
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@docker exec $(CONTAINER_NAME) hermes doctor 2>&1 | tail -25 || true

demo-memory: ## Retain a fact, then recall it in a FRESH session to prove long-term memory
	@if [ -e "$(DATA_DIR)/gateway.sock" ]; then chmod 600 "$(DATA_DIR)/gateway.sock" 2>/dev/null || true; fi
	@echo "### Step 1 - session A: teach Hermes something it cannot infer"
	@# -q, not a positional prompt: `hermes chat` has no positional arg.
	@# Do NOT pass --oneshot: it ends the turn after the first assistant
	@# message, so a tool call is emitted but never executed (0 tool calls).
	@docker exec $(CONTAINER_NAME) hermes chat --cli --max-turns 8 -q \
		"Remember this for later: the hermes-course demo stack uses OmniRoute on port 20128 and Hindsight on port 8888. Use your memory tool to retain it." || true
	@echo ""
	@echo "### Step 2 - session B (fresh context): can it recall?"
	@docker exec $(CONTAINER_NAME) hermes chat --cli --max-turns 8 -q \
		"Which ports do OmniRoute and Hindsight use in the hermes-course demo stack? Recall from memory." || true
	@echo ""
	@echo "### Step 3 - inspect the knowledge graph:  make hindsight-ui"

# ==============================================================================
# OmniRoute FREE combos (keyless routing)
#
# "auto/*" model IDs are OmniRoute's routing chains. The tier suffix ":free"
# (and the auto/best-free variant) filters the candidate pool to free targets.
# Filtering is FAIL-OPEN: if nothing matches, the full pool is used, so a
# ":free" model string is a preference, not a guarantee of zero cost.
#
# Two providers in this build need no credential at all (connectionId "noauth"):
#   cloudflare-playground  - drives a real browser, so the gateway image needs
#                            Chromium (make omniroute-browser-build)
#   uncloseai              - public beta currently CLOSED, returns HTTP 401
# ==============================================================================

FREE_MODEL ?= auto/best-free

omniroute-browser-build: ## Build the OmniRoute image with Chromium (required by the keyless free providers)
	docker build -f docker/Dockerfile.omniroute -t $(OMNIROUTE_BROWSER_IMAGE) .
	@echo ""
	@echo "Built $(OMNIROUTE_BROWSER_IMAGE). Now set in .env:"
	@echo "  OMNIROUTE_IMAGE=$(OMNIROUTE_BROWSER_IMAGE)"
	@echo "Then: docker compose up -d omniroute"

omniroute-key: ## Create an OmniRoute client API key and write it to .env as GTW_API_KEY
	@./docker/omniroute-provision.sh

free-combos: ## Show which keyless (noauth) free candidates OmniRoute can actually reach
	@./docker/omniroute-free-report.sh

free-combo-test: ## Send a real completion through the free combo to prove it works
	@FREE_MODEL=$(FREE_MODEL) ./docker/omniroute-free-report.sh --test

tool-call-check: ## Probe whether a model supports STRUCTURED tool calling (free combos do NOT)
	@FREE_MODEL=$(FREE_MODEL) ./docker/omniroute-toolcall-check.sh || true

provider-free: ## Point BOTH Hermes and Hindsight at the free combo, then restart them
	@docker exec $(CONTAINER_NAME) hermes config set model.provider custom
	@docker exec $(CONTAINER_NAME) hermes config set model.base_url http://omniroute:20128/v1
	@docker exec $(CONTAINER_NAME) hermes config set model.default $(FREE_MODEL)
	@echo "Set Hermes model.default = $(FREE_MODEL)"
	@echo "Hindsight reads HINDSIGHT_API_LLM_MODEL from .env; ensure it is $(FREE_MODEL)."
	@docker compose up -d hermes hindsight
	$(WAIT_SOCK)
	@echo ""
	@echo "Verify: make provider-show && make hindsight-llm-check"

# ==============================================================================
# Langfuse — OTLP trace sink for Hindsight
# ==============================================================================
# Hindsight exports TRACES (not metrics) over OTLP/HTTP to langfuse-web, which
# buffers them in MinIO + Redis; langfuse-worker drains the queue into
# ClickHouse. Six containers: web, worker, postgres, clickhouse, redis, minio.
LANGFUSE_SERVICES := langfuse-web langfuse-worker langfuse-postgres langfuse-clickhouse langfuse-redis langfuse-minio
LANGFUSE_PORT ?= 3000
CH_QUERY = docker exec $(CONTAINER_NAME)-lf-clickhouse clickhouse-client \
	--user "$(LANGFUSE_CLICKHOUSE_USER)" --password "$(LANGFUSE_CLICKHOUSE_PASSWORD)" --query

langfuse-up: ## Start the Langfuse stack (stores -> web runs migrations -> worker)
	@docker compose up -d langfuse-worker
	@echo ""
	@echo "Langfuse UI: http://localhost:$(LANGFUSE_PORT)  (login: $(or $(LANGFUSE_INIT_USER_EMAIL),admin@hermes.local) / $(or $(LANGFUSE_INIT_USER_PASSWORD),hermes-admin))"

langfuse-down: ## Stop and remove ONLY the Langfuse containers (keeps their data)
	@docker compose rm -fs $(LANGFUSE_SERVICES) 2>/dev/null || true
	@echo "Langfuse stopped. Data volumes kept -- 'make langfuse-reset' clears them."

langfuse-logs: ## Tail the Langfuse web + worker logs (app-level, not the stores)
	@docker compose logs -f --tail=100 langfuse-web langfuse-worker

langfuse-ui: ## Open the Langfuse UI in the default browser
	@echo "Opening http://localhost:$(LANGFUSE_PORT)"
	@open http://localhost:$(LANGFUSE_PORT) 2>/dev/null || xdg-open http://localhost:$(LANGFUSE_PORT) 2>/dev/null || true

langfuse-status: ## Show health of all six Langfuse containers
	@docker ps -a --filter "name=$(CONTAINER_NAME)-lf-" --format 'table {{.Names}}\t{{.Status}}'

langfuse-traces: ## Show span counts per service recorded in ClickHouse
	@$(CH_QUERY) "SELECT service_name, name, count() AS spans, max(start_time) AS latest FROM default.events_full GROUP BY service_name, name ORDER BY spans DESC LIMIT 20 FORMAT PrettyCompact" 2>/dev/null \
		|| echo "Could not query ClickHouse. Is the stack up? (make langfuse-status)"

langfuse-otel-header: ## Recompute the OTLP Basic auth header in .env from the Langfuse keys
	@python3 -c "import base64,io,re,sys; \
p='.env'; s=io.open(p,encoding='utf-8').read(); \
g=lambda k:(re.search('^'+k+'=(.*)$$',s,re.M) or sys.exit('missing '+k+' in .env')).group(1).strip(); \
pk=g('LANGFUSE_PUBLIC_KEY'); sk=g('LANGFUSE_SECRET_KEY'); \
h='Authorization=Basic '+base64.b64encode((pk+':'+sk).encode()).decode(); \
k='HINDSIGHT_API_OTEL_EXPORTER_OTLP_HEADERS'; \
s2=re.sub('^'+k+'=.*$$',k+'='+h,s,count=1,flags=re.M) if re.search('^'+k+'=',s,re.M) else s.rstrip()+chr(10)+k+'='+h+chr(10); \
io.open(p,'w',encoding='utf-8').write(s2); \
print('Wrote '+k+' for public key '+pk)"
	@echo "Apply it:  docker compose up -d hindsight"

langfuse-secrets: ## Generate real Langfuse secrets into .env (replaces the local placeholders)
	@python3 -c "import io,re,secrets; \
p='.env'; s=io.open(p,encoding='utf-8').read(); \
vals={'LANGFUSE_SALT':secrets.token_hex(16),'LANGFUSE_NEXTAUTH_SECRET':secrets.token_hex(32),'LANGFUSE_ENCRYPTION_KEY':secrets.token_hex(32)}; \
[s:=(re.sub('^'+k+'=.*$$',k+'='+v,s,count=1,flags=re.M) if re.search('^'+k+'=',s,re.M) else s.rstrip()+chr(10)+k+'='+v+chr(10)) for k,v in vals.items()]; \
io.open(p,'w',encoding='utf-8').write(s); \
print('Rotated: '+', '.join(vals))"
	@echo ""
	@echo "WARNING: rotating SALT or ENCRYPTION_KEY strands data encrypted under the old"
	@echo "values. On an existing install, follow with 'make langfuse-reset'."

langfuse-reset: ## DESTRUCTIVE: drop all Langfuse data volumes and re-migrate from scratch
	@echo "This deletes every trace, project and API key in Langfuse."
	@printf "Type 'reset' to continue: " && read ans && [ "$$ans" = "reset" ] || { echo "Aborted."; exit 1; }
	@docker compose rm -fsv $(LANGFUSE_SERVICES) 2>/dev/null || true
	@# Scoped by BOTH the compose project label and a langfuse- name prefix.
	@# The label keeps other Langfuse stacks on this machine out of it, and the
	@# name prefix keeps hindsight-pgdata and hermes-installs -- which hold the
	@# agent's actual memory and plugin environments -- out of it. Never use
	@# `docker compose down --volumes` here: that would take both of those too.
	@vols=$$(docker volume ls -q \
		--filter "label=com.docker.compose.project=$$(docker compose config --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')" \
		--filter "name=langfuse-"); \
	if [ -n "$$vols" ]; then echo "Removing:"; echo "$$vols" | sed 's/^/  /'; docker volume rm -f $$vols >/dev/null; \
	else echo "No Langfuse volumes found."; fi
	@echo "Volumes cleared. Recreating..."
	@docker compose up -d langfuse-worker
	@echo "Done. The seeded project and keys are recreated from LANGFUSE_INIT_* in .env."

langfuse-verify: ## Prove the whole path: Hindsight -> OTLP -> Langfuse -> ClickHouse
	@echo "1/4 Langfuse web health"
	@curl -fsS --max-time 10 http://localhost:$(LANGFUSE_PORT)/api/public/health >/dev/null \
		&& echo "    OK  http://localhost:$(LANGFUSE_PORT)" \
		|| { echo "    FAIL  web not serving -- make langfuse-logs"; exit 1; }
	@echo "2/4 Hindsight tracing initialized"
	@docker logs $(CONTAINER_NAME)-hindsight 2>&1 | grep -q "OpenTelemetry tracing enabled" \
		&& docker logs $(CONTAINER_NAME)-hindsight 2>&1 | grep "Tracing initialized" | tail -1 | sed 's/^/    /' \
		|| { echo "    FAIL  no tracing in hindsight logs."; \
		     echo "    Both HINDSIGHT_API_OTEL_TRACES_ENABLED and ..._OTLP_ENDPOINT must be set,"; \
		     echo "    then: docker compose up -d hindsight"; exit 1; }
	@echo "3/4 Generating Hindsight API traffic"
	@for i in 1 2 3; do curl -fsS --max-time 15 -o /dev/null http://localhost:$(or $(HINDSIGHT_API_PORT),8888)/v1/default/banks || true; done
	@echo "    sent 3 requests to /v1/default/banks"
	@echo "4/4 Spans in ClickHouse (allowing for the 5s batch delay + worker)"
	@curl -fsS --max-time 30 --retry 4 --retry-delay 7 --retry-all-errors -o /dev/null http://localhost:$(LANGFUSE_PORT)/api/public/health || true
	@$(CH_QUERY) "SELECT service_name, count() AS spans FROM default.events_full WHERE service_name='hindsight-api' GROUP BY service_name FORMAT PrettyCompact" 2>/dev/null | sed 's/^/    /' \
		|| echo "    Could not query ClickHouse"
	@echo ""
	@echo "If span count is 0, wait ~10s and re-run: spans are batched, then queued."

# ==============================================================================
# Webhook relay — prove Hindsight <-> Hermes reachability (opt-in)
# ==============================================================================
# One container behind the `webhook` compose profile, so `make up` never starts
# it. POST /hook fans out to Hindsight (recall) and Hermes (chat completion) and
# reports each leg separately. Needs API_SERVER_ENABLED=true and a non-empty
# API_SERVER_KEY in .env for the Hermes leg.
WEBHOOK_TEST_PORT ?= 8777

webhook-up: ## Start the opt-in webhook relay (profile: webhook)
	@docker compose --profile webhook up -d webhook-test
	@echo "Webhook relay: http://localhost:$(WEBHOOK_TEST_PORT)  (make webhook-test)"

webhook-down: ## Stop and remove ONLY the webhook relay container
	@docker compose --profile webhook rm -fs webhook-test 2>/dev/null || true
	@echo "Webhook relay stopped."

webhook-logs: ## Tail the webhook relay log (every delivery + leg statuses)
	@docker compose --profile webhook logs -f --tail=100 webhook-test

webhook-test: ## Fire a sample delivery at POST /hook and print the round-trip report
	@curl -sS -m 120 -X POST "http://localhost:$(WEBHOOK_TEST_PORT)/hook" \
		-H 'Content-Type: application/json' \
		-d '{"event":"webhook.test","source":"make webhook-test"}' \
		| python3 -I -c 'import json,sys; d=json.load(sys.stdin); \
	[print("  %-9s status=%s ok=%s %sms %s" % (k, d[k]["status"], d[k]["ok"], d[k]["ms"], d[k].get("error") or d[k]["body_excerpt"][:120])) for k in ("hindsight","hermes")]; \
	print("  round_trip_ok =", d["round_trip_ok"]); sys.exit(0 if d["round_trip_ok"] else 1)'

webhook-log: ## Show the last deliveries recorded by the relay (GET /log)
	@curl -sS "http://localhost:$(WEBHOOK_TEST_PORT)/log" | python3 -m json.tool
