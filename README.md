# bc-hermes-agent

A self-contained Docker stack for the **Hermes Agent** course: the Nous Research
Hermes Agent, an OpenAI-compatible inference gateway in front of it, a
self-hosted long-term-memory server behind it, and an optional LLM
observability backend collecting OTLP traces.

Everything is driven from a single `Makefile`. State lives on the host under
`./data` and `./workspace`, so the stack can be torn down and rebuilt without
losing the agent's memory, plugins or profiles.

---

## Table of contents

- [What's in the stack](#whats-in-the-stack)
- [Data flow](#data-flow)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration (`.env`)](#configuration-env)
- [Ports](#ports)
- [Volumes and persistence](#volumes-and-persistence)
- [Makefile reference](#makefile-reference)
- [Scripts in `docker/`](#scripts-in-docker)
- [Custom images](#custom-images)
- [Long-term memory (Hindsight)](#long-term-memory-hindsight)
- [Inference routing (OmniRoute)](#inference-routing-omniroute)
- [Observability (Langfuse)](#observability-langfuse)
- [Operational runbook / troubleshooting](#operational-runbook--troubleshooting)
- [Documentation in `docs/`](#documentation-in-docs)

---

## What's in the stack

`docker-compose.yml` defines **nine services** on one bridge network,
`hermes-net`. Three are the core stack; six more make up the optional Langfuse
group.

### Core

| Service | Container | Image | Role |
|---|---|---|---|
| `hermes` | `hermes-agent` | built from `docker/Dockerfile` (base `nousresearch/hermes-agent:stable`) | The agent. Runs `gateway run` under s6-overlay, exposes an OpenAI-compatible API on `:8642` and **serves the web dashboard on `:9119` from the same container**. |
| `omniroute` | `hermes-agent-gtw` | `ghcr.io/diegosouzapw/omniroute:latest` | AI gateway: one OpenAI-compatible `/v1` endpoint in front of many upstream providers, plus a web dashboard. |
| `hindsight` | `hermes-agent-hindsight` | `ghcr.io/vectorize-io/hindsight:latest` | Self-hosted long-term memory — knowledge graph, entity resolution, multi-strategy retrieval. Bundles its own PostgreSQL + pgvector. Embeddings and reranking run locally inside the container. |

There is **no separate dashboard container**. The official Hermes image is
s6-overlay supervised: `gateway run` is redirected to the supervised service,
which also starts the dashboard whenever `HERMES_DASHBOARD` is truthy
(`1`/`true`/`yes`). Running a second container off the same `./data` bind mount
would mean two writers against the same SQLite/WAL files and two gateway
supervisors over one `gateway.sock`. Set `HERMES_DASHBOARD=0` to run the agent
without the UI.

### Langfuse group (optional)

Langfuse v4 is not a single container — the web app, an async ingestion worker
and four stores are all required:

| Service | Container | Port | Role |
|---|---|---|---|
| `langfuse-web` | `hermes-agent-lf-web` | 3000 | UI **and** the OTLP endpoint Hindsight posts to. Owns all migrations (Prisma + ClickHouse). |
| `langfuse-worker` | `hermes-agent-lf-worker` | 3030 (internal) | Drains the ingestion queue into ClickHouse. |
| `langfuse-postgres` | `hermes-agent-lf-postgres` | 5432 (internal) | Transactional data: orgs, projects, API keys. |
| `langfuse-clickhouse` | `hermes-agent-lf-clickhouse` | 8123 / 9000 (internal) | The actual trace/span store. |
| `langfuse-redis` | `hermes-agent-lf-redis` | 6379 (internal) | Ingestion queue + cache. |
| `langfuse-minio` | `hermes-agent-lf-minio` | 9000 / 9001 (internal) | S3-compatible blob storage for raw ingestion events. |

Startup order matters and is enforced with healthchecks: the four stores must be
healthy → `langfuse-web` boots and runs every migration → `langfuse-worker`
starts. The worker runs **no** migrations of its own; starting it against an
unmigrated database makes it spin forever on `relation "monitors" does not
exist`.

**Cost:** ClickHouse alone reserves roughly 1 GB RAM. With Hermes, OmniRoute
(which can carry Chromium) and Hindsight (which carries its own PostgreSQL)
already running, this group roughly doubles the stack's footprint. Drop it with
`make langfuse-down`, or set `HINDSIGHT_API_OTEL_TRACES_ENABLED=false` to keep
it off for good.

---

## Data flow

```
                      ┌──────────────────────────────┐
   you ──► make chat ─┤  hermes  (hermes-agent)      │
                      │  + Web UI :9119 (s6)         │
                      └───┬──────────────────┬───────┘
         inference        │                  │   long-term memory
   /v1/chat/completions   │                  │   /v1/default/banks/...
                          ▼                  ▼
              ┌───────────────────┐   ┌─────────────────────────┐
              │ omniroute :20128  │   │ hindsight :8888 (API)   │
              │ (AI gateway)      │◄──┤          :9999 (UI)     │
              └─────────┬─────────┘   │ embedded PostgreSQL +   │
                        │             │ pgvector, local embeds  │
                        ▼             └───────────┬─────────────┘
          upstream LLM providers                  │ OTLP/HTTP traces
          (OpenAI, Anthropic, OpenRouter, ...)    ▼
                                      ┌─────────────────────────┐
                                      │ langfuse-web :3000      │
                                      │  → redis/minio → worker │
                                      │  → clickhouse           │
                                      └─────────────────────────┘
```

Note the second arrow into OmniRoute: **Hindsight also calls the gateway.** It
needs an LLM to extract entities and synthesize reflections, and by default it
is pointed at OmniRoute too — so the whole stack needs exactly one upstream
credential, configured once in the OmniRoute dashboard and shared by all three
components.

---

## Repository layout

```
.
├── Makefile                 # every operation; `make help` lists all targets
├── docker-compose.yml       # the 9 services, networks and volumes
├── .env.example             # every tunable, documented inline
├── .gitignore               # excludes .env, ./data, ./workspace, ./data-gtw, *.bak-*
├── docker/
│   ├── Dockerfile                        # Hermes agent image (thin layer over the official one)
│   ├── Dockerfile.omniroute              # OmniRoute + Chromium, for the keyless free providers
│   ├── Dockerfile.hindsight              # Hindsight + tolerant consolidation parsing
│   ├── hindsight-tolerant-batch.patch.py # the vendor patch applied by Dockerfile.hindsight
│   ├── write-hindsight-config.sh         # render ./data/hindsight/config.json from .env
│   ├── hindsight-roundtrip.sh            # prove retain → extract → recall
│   ├── hindsight-consolidate.sh          # trigger a consolidation round and judge the result
│   ├── hindsight-unstick.sh              # recover tasks orphaned by a stale worker lease
│   ├── omniroute-provision.sh            # mint a gateway API key into .env
│   ├── omniroute-free-report.sh          # what the keyless/free routing can reach
│   └── omniroute-toolcall-check.sh       # does this model do structured tool calls?
└── docs/
    ├── guides/DOCKER_HERMES_GUIDE.md     # long-form guide to this stack
    ├── guides/hermes_docker_guide.html
    ├── course/Hermes_Zero_to_Hero_v0.1_Codex.html   # "Hermes Agent · Five-Day Technical Course"
    └── diagrams/                         # hermes-stack, hermes-architecture, hermes-auth-data-flow
                                          #   (.html + .delivery.json each)
```

Runtime directories (`./data`, `./workspace`, `./data-gtw`) are created by
`make setup-dirs` and are git-ignored.

---

## Prerequisites

- **Docker** with Compose v2 (`docker compose`, not `docker-compose`).
- **GNU make**.
- **Python 3** on the host — the Makefile and several scripts use it for JSON
  and secret handling. Scripts invoke it as `python3 -I` (isolated mode).
- `rsync` for the `sync-from-host` / `sync-to-host` targets.
- Developed and documented against **macOS + Docker Desktop**; several
  workarounds in this repo exist specifically for the macOS virtiofs bind mount
  (see [Operational runbook](#operational-runbook--troubleshooting)).
- RAM: the core three services are modest; add ~1 GB+ if you run the Langfuse
  group.

---

## Quick start

```bash
make setup-dirs       # create ./data ./workspace ./data-gtw, copy .env.example → .env
make build            # build the Hermes image
make up               # start the stack in the background
make omniroute-key    # mint an OmniRoute API key and write GTW_API_KEY into .env
make restart          # Hermes + Hindsight pick up the new key
make verify           # walk the whole stack and report what is actually wired
```

Then open a dashboard:

```bash
make webui            # Hermes Web UI      http://localhost:9119  (admin / hermes-admin)
make gtw-dashboard    # OmniRoute          http://localhost:20128 (password: omniroute-admin)
make hindsight-ui     # memory explorer    http://localhost:9999
make langfuse-ui      # Langfuse           http://localhost:3000  (admin@hermes.local / hermes-admin)
```

To enable long-term memory:

```bash
make hindsight-install    # install the pinned plugin into ./data/plugins
make hindsight-enable     # write config.json, set memory.provider=hindsight, restart
make hindsight-roundtrip  # prove retain → extract → recall with a canary fact
```

And to talk to the agent:

```bash
make chat     # classic CLI chat session
make tui      # rich Ink TUI
make model    # interactive model/provider selector
```

> **`make omniroute-key` is not optional on a fresh stack.** OmniRoute's `/v1`
> endpoint rejects any bearer token that does not exist in its own database,
> **even with `OMNIROUTE_REQUIRE_API_KEY=false`**. The shipped
> `GTW_API_KEY=omniroute-local` is a placeholder, so without this step every
> request 401s.

---

## Configuration (`.env`)

`make setup-dirs` copies `.env.example` to `.env` if none exists. The Makefile
`include`s and exports `.env`, and `docker-compose.yml` interpolates it. Every
variable has a default in the compose file, so `.env` only needs the overrides
you care about. `.env` is git-ignored; `.env.example` documents every key
inline.

### Core / Hermes

| Variable | Default | Notes |
|---|---|---|
| `HERMES_IMAGE` | `nousresearch/hermes-agent:stable` | Build arg `BASE_IMAGE` for `docker/Dockerfile`. |
| `HERMES_IMAGE_TAG` | `hermes-agent-local:latest` | Tag of the locally built image. |
| `CONTAINER_NAME` | `hermes-agent` | Prefix for every container name in the stack. |
| `HERMES_UID` / `HERMES_GID` | host `id -u` / `id -g` | Ownership inside the container. |
| `DATA_DIR` | `./data` | Bind-mounted to `/opt/data` (= `HERMES_HOME`). |
| `WORKSPACE_DIR` | `./workspace` | Bind-mounted to `/workspace`. |
| `API_SERVER_ENABLED` | `false` | Enables the OpenAI-compatible API on `:8642`. |
| `API_SERVER_KEY` | *(empty)* | Bearer token for that API. |
| `API_SERVER_PORT` | `8642` | Published port. |
| `HERMES_DASHBOARD` | `1` | `0` disables the supervised web UI. |
| `DASHBOARD_PORT` | `9119` | Published port for the web UI. |
| `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` | `admin` / `hermes-admin` | Basic auth. **A non-loopback bind requires an auth provider or the server fails closed**; `HERMES_DASHBOARD_INSECURE` is accepted but ignored since the June 2026 hardening. |
| `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` | *(empty)* | Passed through when set; see `make bot-setup`. |

### OmniRoute

| Variable | Default | Notes |
|---|---|---|
| `OMNIROUTE_IMAGE` | `ghcr.io/diegosouzapw/omniroute:latest` | Set to `omniroute-browser:local` to use the Chromium-enabled build. |
| `OMNIROUTE_PORT` | `20128` | Dashboard **and** `/v1` endpoint. |
| `OMNIROUTE_DATA_DIR` | `./data-gtw` | Bind-mounted to `/app/data`. |
| `OMNIROUTE_REQUIRE_API_KEY` | `false` | Does **not** make `/v1` accept unknown tokens. |
| `OMNIROUTE_INITIAL_PASSWORD` | `omniroute-admin` | Seeds the dashboard password on **first boot only**. |
| `OMNIROUTE_EXCLUDE_TOS_AVOID` | `true` | Keeps `tos:avoid` providers out of auto routing. |
| `PLAYWRIGHT_BROWSERS_PATH` | `/ms-playwright` | Where Chromium lives in the browser-enabled image; harmless otherwise. |
| `GTW_API_KEY` | `omniroute-local` | Bearer token used by Hermes *and* Hindsight. `make omniroute-key` writes a real one. |
| `FREE_MODEL` | `auto/best-free` | Model ID used by the free-combo and tool-call probes. |

### Hindsight (server side — `HINDSIGHT_API_*`)

| Variable | Default | Notes |
|---|---|---|
| `HINDSIGHT_IMAGE` / `HINDSIGHT_VERSION` | `ghcr.io/vectorize-io/hindsight` / `latest` | Set to `hindsight-patched` / `local` to use the patched build. |
| `HINDSIGHT_API_PORT` / `HINDSIGHT_UI_PORT` | `8888` / `9999` | REST API (+ per-bank MCP at `/mcp/{bank_id}/`) and memory explorer. |
| `HINDSIGHT_DATA_VOLUME` | `hindsight-pgdata` | A **named volume** by default. Override with a `./path` to bind-mount it. |
| `HINDSIGHT_API_LLM_PROVIDER` / `_BASE_URL` / `_MODEL` | `openai` / `http://omniroute:20128/v1` / `auto/best-free` | The model used for **extraction and reflection**. Independent of the chat model. |
| `HINDSIGHT_API_LLM_API_KEY` | falls back to `GTW_API_KEY` | **Hindsight refuses to boot if this is empty** (`ValueError: LLM API key is required`). It only checks non-emptiness at startup. |
| `HINDSIGHT_API_ENABLE_BANK_LLM_HEALTH` | `true` | Enables the real-call probe behind `make hindsight-llm-check`. |
| `HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION` | `true` | Disabling it does **not** stop consolidation — a background worker claims tasks independently; it only suppresses the inline post-retain trigger. |
| `HINDSIGHT_API_CONSOLIDATION_LLM_MODEL` | `cfp/deepseek-ai/deepseek-v4-flash-0731` (compose) / `auto/chat` (`.env.example`) | Pinned deliberately — see [consolidation](#consolidation-the-bare-list-validationerror). |
| `HINDSIGHT_API_CONSOLIDATION_LLM_REASONING_EFFORT` | `low` | A reasoning-heavy model burns its whole output budget thinking and gets truncated. |
| `HINDSIGHT_API_CONSOLIDATION_LLM_BATCH_SIZE` | `2` | Keeps the required JSON short. |
| `HINDSIGHT_API_OTEL_TRACES_ENABLED` | `true` | **Both** this and the endpoint must be set or tracing silently no-ops. |
| `HINDSIGHT_API_OTEL_EXPORTER_OTLP_ENDPOINT` | `http://langfuse-web:3000/api/public/otel` | A **base** URL — Hindsight appends `/v1/traces` itself. |
| `HINDSIGHT_API_OTEL_EXPORTER_OTLP_HEADERS` | *(empty)* | `Authorization=Basic base64(public:secret)`. `make langfuse-otel-header` computes it. |
| `HINDSIGHT_API_OTEL_SERVICE_NAME` / `_DEPLOYMENT_ENVIRONMENT` | `hindsight-api` / `hermes-course` | Span attribution. |
| `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS` | `health,metrics` | Keeps probe traffic out of the trace stream. |

### Hindsight (client side — read by the Hermes plugin)

| Variable | Default | Notes |
|---|---|---|
| `HINDSIGHT_MODE` | `local_external` | One of `cloud`, `local_external`, `local_embedded`. |
| `HINDSIGHT_API_URL` | `http://hindsight:8888` | In `local_external` the plugin runs **inside** the Hermes container, so this is the compose service name — not `localhost`. |
| `HINDSIGHT_API_KEY` | *(empty)* | Required in `cloud` mode. |
| `HINDSIGHT_BANK_ID` | `hermes-course` | The memory bank. |
| `HINDSIGHT_MEMORY_MODE` | `hybrid` (script default) / `context` (`.env.example`) | `context` = injection only, for models without real tool calling. |
| `HINDSIGHT_BUDGET` | `mid` | Recall budget. |
| `HINDSIGHT_RECALL_TYPES` | `observation,world,experience` | Hindsight's own default is `observation` only, which hides raw facts from recall. |
| `HINDSIGHT_AUTO_RETAIN` | `true` | |
| `HINDSIGHT_TIMEOUT` | `120` | Seconds. |

### Langfuse

| Variable | Default | Notes |
|---|---|---|
| `LANGFUSE_VERSION` | `4` | Image tag for web and worker. |
| `LANGFUSE_PORT` | `3000` | Published UI port. |
| `LANGFUSE_NEXTAUTH_URL` | `http://localhost:3000` | **Must match the URL you open in the browser**, or the login redirect bounces. |
| `LANGFUSE_CLICKHOUSE_IMAGE` | `clickhouse/clickhouse-server:25.12` | **Do not downgrade** — see [the ClickHouse note](#langfuse-web-crash-loops-on-dirty-database-version-39). |
| `LANGFUSE_ENCRYPTION_KEY` | 64 zeros | Must be **exactly 64 hex characters**. |
| `LANGFUSE_SALT`, `LANGFUSE_NEXTAUTH_SECRET` | placeholders | `make langfuse-secrets` generates real ones. Rotating `SALT` or `ENCRYPTION_KEY` strands existing data. |
| `LANGFUSE_INIT_*` | `hermes-course` / `admin@hermes.local` / `hermes-admin` | Headless bootstrap: seeds org, project, user and API keys so OTLP works on the **first** `make up` with no manual signup. Applied only when the database is empty. |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | `pk-lf-hermes-course` / `sk-lf-hermes-course` | Seeded project keys; also authenticate Hindsight's OTLP exporter. |
| `LANGFUSE_POSTGRES_*`, `LANGFUSE_CLICKHOUSE_*`, `LANGFUSE_REDIS_PASSWORD`, `LANGFUSE_S3_*` | `langfuse-local` etc. | Store credentials. Langfuse refuses an unauthenticated Redis even on a private network. |
| `LANGFUSE_TELEMETRY_ENABLED` | `false` | |

`LANGFUSE_INIT_PROJECT_RETENTION` is deliberately **not** set — unset means
"keep traces indefinitely". It is validated as a number ≥ 3 (days), so there is
no "0 means forever"; passing `0` fails startup outright.

---

## Ports

| Host port | Service | What |
|---|---|---|
| `9119` | hermes | Web dashboard (basic auth) |
| `8642` | hermes | OpenAI-compatible API (only when `API_SERVER_ENABLED=true`) |
| `20128` | omniroute | Dashboard **and** OpenAI-compatible `/v1` endpoint |
| `8888` | hindsight | REST API + per-bank MCP endpoint `/mcp/{bank_id}/` |
| `9999` | hindsight | Memory explorer UI (knowledge-graph browser) |
| `3000` | langfuse-web | UI + OTLP ingest endpoint |

The remaining Langfuse stores are reachable only on `hermes-net`.

---

## Volumes and persistence

**Bind mounts (host):**

- `./data` → `/opt/data` — `HERMES_HOME`: config, profiles, `state.db`,
  `kanban.db`, `plugins/`, `hindsight/config.json`, `gateway.sock`.
- `./workspace` → `/workspace` — project and I/O files.
- `./data-gtw` → `/app/data` — OmniRoute's database (providers, API keys).

**Named volumes:**

- `hermes-installs` → `/opt/data/installs` — plugin Python dependency
  environments.
- `hindsight-pgdata` → `/home/hindsight/.pg0` — Hindsight's embedded PostgreSQL.
- `langfuse-pgdata`, `langfuse-clickhouse-data`, `langfuse-clickhouse-logs`,
  `langfuse-miniodata`.

### Why those two are named volumes and not bind mounts

**`hermes-installs`** — the macOS bind mount is **case-insensitive**, and Hermes
copies a Python toolchain containing both `share/terminfo/a` and
`share/terminfo/A` into `/opt/data/installs`. They collide and plugin dependency
builds fail. A named volume is ext4 inside the Docker VM, so the collision
disappears.

**`hindsight-pgdata`** (and the Langfuse stores) — PostgreSQL and ClickHouse on
a macOS virtiofs bind mount are both slow and **fsync-unsafe**. Override
`HINDSIGHT_DATA_VOLUME` with a `./path` only if you accept that.

### Why the Hindsight plugin is not baked into the image

`hermes plugins install hindsight` writes to `$HERMES_HOME/plugins`, and
`HERMES_HOME` is `/opt/data` — which compose bind-mounts over from `./data`.
Anything the Dockerfile writes there is **shadowed at runtime** and invisible to
the agent; baking it in would produce an image that looks right and behaves as
if the plugin were missing.

Instead it is installed once at runtime (`make hindsight-install`, pinned to an
immutable commit SHA) and persists in `./data/plugins` on the host, surviving
`docker compose down`, `up`, `--force-recreate` and image rebuilds. Only
`make destroy` removes it.

---

## Makefile reference

`make help` prints this list from the Makefile itself.

### Lifecycle

| Target | Does |
|---|---|
| `setup-dirs` | Create `./data`, `./workspace`, `./data-gtw`, `./data/hindsight`; fix permissions; copy `.env.example` → `.env` if absent |
| `build` | `docker compose build` |
| `up` | `docker compose up -d`, then repair ownership on `/opt/data/installs` |
| `down` | `docker compose down` |
| `restart` | `down` then `up` |
| `update-image` | `docker compose pull` + `up -d --force-recreate` |
| `clean` | `docker compose down --remove-orphans -v` (keeps `./data`) |
| `destroy` | **Destructive, prompts:** `down -v --rmi all` and `rm -rf ./data ./workspace` |

### Inspect / interact

| Target | Does |
|---|---|
| `ps` | `docker compose ps` |
| `status` | `ps` + `hermes doctor` inside the container |
| `logs` / `dashboard-logs` | Tail the Hermes service / just the dashboard lines |
| `shell` | `bash` inside the container |
| `chat` / `tui` / `console` / `model` | Hermes CLI chat, Ink TUI, admin console, model selector |
| `webui` / `gtw-dashboard` / `hindsight-ui` / `langfuse-ui` | Open the respective UI in a browser |
| `doctor-fix` | `hermes doctor --fix` |
| `setup-keys` | Interactive `hermes setup` for provider credentials |
| `fix-permissions` | Repair `gateway.sock` mode and the installs volume ownership |

### Profiles, bots, host sync

| Target | Does |
|---|---|
| `profile-list` | List configured profiles |
| `profile-create NAME=x [CLONE=1]` | Create a profile; `CLONE=1` also unsets `TELEGRAM_BOT_TOKEN` and `API_SERVER_ENABLED` on the clone to avoid a gateway collision |
| `profile-use NAME=x` | Switch the default profile |
| `bot-setup` / `bot-start` / `bot-logs` | Messaging gateway (Telegram, Discord, Slack) |
| `sync-from-host` | `rsync ~/.hermes/` → `./data/` |
| `sync-to-host` | `rsync ./data/` → `~/.hermes/`, after a timestamped backup |

### Hindsight memory

| Target | Does |
|---|---|
| `hindsight-install` | Install the plugin pinned at `HINDSIGHT_PLUGIN_SHA` (`d952b6e6…`) with `--yes-deps --enable --force` |
| `hindsight-config` | Regenerate `./data/hindsight/config.json` from `.env` (backs up the old one) |
| `hindsight-enable` | `hindsight-config` + `hermes config set memory.provider hindsight` + restart |
| `hindsight-disable` | `hermes memory off` + restart (built-in `MEMORY.md`/`USER.md` memory stays active) |
| `hindsight-status` | `hermes memory status` |
| `hindsight-health` | `GET /health/ready` **from inside the Hermes container** — proves the network link |
| `hindsight-banks` | List memory banks (a bank appears only after the first retain) |
| `hindsight-llm-check` | `POST .../health/llm` — proves the Hindsight → OmniRoute → upstream leg with a real call |
| `hindsight-roundtrip` | Canary retain → extract → recall, independent of the chat model |
| `hindsight-consolidate` | Trigger a consolidation round and judge created/updated vs. schema errors |
| `hindsight-unstick` | Recover consolidation tasks orphaned by a stale worker lease |
| `hindsight-patched-build` | Build `hindsight-patched:local` from `docker/Dockerfile.hindsight` |
| `hindsight-logs` / `hindsight-shell` | Tail logs / open a shell in the memory server |

### Inference routing

| Target | Does |
|---|---|
| `provider-show` | Print `model.provider`, `model.base_url`, `model.default` |
| `provider-omniroute` | `model.provider=custom`, `base_url=http://omniroute:20128/v1`, restart |
| `provider-direct` | `model.provider=openrouter`, `base_url=https://openrouter.ai/api/v1`, restart (needs `OPENROUTER_API_KEY` in `./data/.env`) |
| `provider-free` | Point **both** Hermes and Hindsight at `FREE_MODEL`, then restart them |
| `omniroute-models` | `GET /v1/models` from inside the Hermes container, with a 401 explainer |
| `omniroute-key` | Mint a gateway API key and write it to `.env` as `GTW_API_KEY` |
| `omniroute-browser-build` | Build `omniroute-browser:local` with Chromium |
| `free-combos` / `free-combo-test` | Report the keyless candidate pool / send a real completion through it |
| `tool-call-check` | Probe whether a model emits **structured** `tool_calls` |
| `gtw-logs` | Tail the gateway logs |

### Verification & demos

| Target | Does |
|---|---|
| `verify` | Eight-step walk: container status → OmniRoute reachability → Hindsight reachability → routing → plugin installed → memory provider → banks → `hermes doctor`. No TTY required, so it works in a pipe or CI |
| `demo-memory` | Session A teaches a fact, session B recalls it in a **fresh context**. Uses `--max-turns 8 -q`; deliberately **not** `--oneshot`, which ends the turn after the first assistant message so a tool call is emitted but never executed |

### Langfuse

| Target | Does |
|---|---|
| `langfuse-up` | `up -d langfuse-worker` (dependency order pulls in the rest in the right sequence) |
| `langfuse-down` | Remove only the six Langfuse containers, keeping their data |
| `langfuse-status` | Health of all six containers |
| `langfuse-logs` | Tail web + worker (app-level, not the stores) |
| `langfuse-traces` | Span counts per service, queried from ClickHouse |
| `langfuse-otel-header` | Recompute `HINDSIGHT_API_OTEL_EXPORTER_OTLP_HEADERS` in `.env` from the Langfuse keys |
| `langfuse-secrets` | Generate real `LANGFUSE_SALT`, `_NEXTAUTH_SECRET`, `_ENCRYPTION_KEY` into `.env` |
| `langfuse-reset` | **Destructive, prompts for `reset`:** drop the Langfuse volumes and re-migrate. Scoped by both the compose project label and a `langfuse-` name prefix, so `hindsight-pgdata` and `hermes-installs` are never touched |
| `langfuse-verify` | Four steps: web health → tracing initialized in the Hindsight log → generate API traffic → count spans in ClickHouse |

---

## Scripts in `docker/`

All of them are invoked by Makefile targets but can be run directly. They read
their configuration from the environment, with the same defaults as the
Makefile.

### `write-hindsight-config.sh` — render the plugin profile
`make hindsight-config`

The plugin reads, in order: `$HERMES_HOME/hindsight/config.json`, then
`~/.hindsight/config.json`, then `HINDSIGHT_*` env vars. **Because the profile
file wins, a stale file silently overrides everything you set in `.env`** —
which is exactly how a demo ends up pointing at the wrong server. So the file is
generated rather than hand-edited. It backs up any existing config to
`config.json.bak-<timestamp>`, writes mode `0600`, picks the right default URL
per `HINDSIGHT_MODE`, and warns if `cloud` mode has no API key.

### `hindsight-roundtrip.sh` — the honest memory test
`make hindsight-roundtrip`

Counts facts in the bank, POSTs a unique canary fact
(`QUETZAL-<timestamp>`), counts again, then recalls it and reports the rank at
which the canary came back. **Deliberately bypasses the agent**: `make
demo-memory` additionally depends on the model choosing to use injected
context, which free keyless models do unreliably — this tests the store itself.
The retain step runs the extraction LLM and can take 30–150 s on free combos.

### `hindsight-consolidate.sh` — trigger and judge a consolidation round
`make hindsight-consolidate`

Prints the consolidation model in use, counts existing `ValidationError`s in the
log, POSTs `/consolidation/recover` (skip with `RECOVER=0`), POSTs
`/consolidate`, waits up to 15 minutes for the `[CONSOLIDATION] … created= …
updated= … skipped= … failed=` summary, then gives a verdict: **FAIL** on new
validation errors, **PASS** if writes happened, **INCONCLUSIVE** if nothing was
left to merge.

The `/consolidation/recover` call matters: facts that a previous failed round
marked `consolidation_failed_at` are **excluded from future rounds**, so after
fixing the cause a plain `/consolidate` reports "0 processed" and looks fine.

### `hindsight-unstick.sh` — clear an orphaned worker lease
`make hindsight-unstick`

Hindsight's background worker claims queued tasks under a lease keyed to its
worker id. **Recreating or replacing the container** (an env change, a
`--force-recreate`, an image bump) kills that worker while the lease still
points at it, and a new worker will not steal the task. The queue then sits like
this forever, with nothing logged as an error:

```
global: pending=1 ... others: 9454be36ad5d:1 ... my_active: none
[PENDING_BREAKDOWN] consolidation: total=1 payload_null=0 retry_blocked=0 assigned=0
```

Worse, POSTing `/consolidate` again returns `{"deduplicated": true}` and folds
into the **same** stuck task, so retrying looks like it worked and does nothing.

The fix is a restart, which runs the startup consolidation reconcile and
reclaims tasks whose worker is gone. The script prints the queue state before,
restarts, waits for healthy, and waits for a fresh `WORKER_STATS` poll. When
`others:` reads `none` and `pending=0`, the orphan is cleared — then re-trigger
with `make hindsight-consolidate`.

### `omniroute-provision.sh` — mint a gateway key
`make omniroute-key`

Logs in over the same HTTP API the dashboard uses and creates a client API key,
so `make up` can reach a working state without a browser. It is careful in three
ways:

1. If `.env` already holds a **working** key it exits without churning the file.
2. It never trusts a key it did not just mint — `/api/keys` returns **masked**
   values when `allowKeyReveal` is false, and those 401. Every candidate is
   verified against `/v1/models` first.
3. It backs `.env` up and rewrites it in Python rather than `sed -i`, because a
   key can contain characters `sed` would treat as delimiters.

It does **not** create provider connections. Keyless (`noauth`) providers need
none; anything with a credential or OAuth flow still has to be done by hand in
the dashboard.

### `omniroute-free-report.sh` — what free routing can actually reach
`make free-combos`, or `make free-combo-test` / `--test` to send a real completion

Reports the keyless candidate pool (count by provider, how many are `noauth`,
reachable, excluded) and the free routing model IDs the gateway advertises.
With `--test` it POSTs a real completion through `FREE_MODEL` and, on failure,
lists every candidate's refusal plus the common causes.

> `auto/*` model IDs are routing chains. A `:free` tier suffix (and the
> `auto/best-free` variant) filters the candidate pool to free targets, but the
> filter is **fail-open** — if nothing matches, the full pool is used. A
> `:free` model string is a **preference, not a cost guarantee.**

### `omniroute-toolcall-check.sh` — the capability check that matters most
`make tool-call-check [FREE_MODEL=…]`

Sends a request with a `get_weather` tool and reports whether the response
contains a structured `tool_calls` array. The keyless
`cloudflare-playground` provider that backs the free combos **scrapes a browser
playground**: it returns the model's prose, never a `tool_calls` array. Hermes
therefore records "0 tool calls" while the model's intended call leaks into the
message body as plain text. **Agents silently cannot use any tool on such a
model** — use `HINDSIGHT_MEMORY_MODE=context` (injection only) there, and a
provider with real function calling for any tool-using demo.

Exit codes: `0` structured calls present, `1` absent, `2` request failed.

---

## Custom images

### `docker/Dockerfile` — the Hermes agent
A thin layer over `nousresearch/hermes-agent:stable`. It creates
`/opt/data/installs` and `/workspace` and sets ownership. Creating
`/opt/data/installs` **in the image** is load-bearing: compose mounts a named
volume there, and Docker seeds a new named volume from the image's mountpoint,
including owner and mode. Without it Docker creates the mountpoint `root:root
0755`, the worker (uid 1000) cannot write, and plugin installs fail with
`Permission denied: /opt/data/installs/<id>`.

`CMD` is `["gateway", "run"]`. **Do not add `--no-supervise`** — that opts out
of s6 and makes the gateway the container's only process, which also disables
the dashboard.

### `docker/Dockerfile.omniroute` — OmniRoute + Chromium
`make omniroute-browser-build` → set `OMNIROUTE_IMAGE=omniroute-browser:local`

The published image ships the `playwright` npm package but **not** the Chromium
binary, and its biggest keyless provider drives a real browser. Without
Chromium every free-tier request fails with HTTP 503 ("Cloudflare Playground
needs Playwright and its Chromium browser"). No browser-enabled tag is
published upstream, so this adds the runtime in a derived layer:

- Installs to `/ms-playwright`, not `$HOME/.cache` — the build runs as root but
  the server runs as uid 1000, and a browser under `/root/.cache` would be
  unreadable at runtime.
- Invokes `node /app/node_modules/playwright-core/cli.js` directly. `npx
  playwright` does **not** work in this image: the bundled `playwright` package
  declares `bin → cli.js` but that file is absent from the pruned install, so
  npx exits 127.
- `--with-deps` pulls the Debian libraries Chromium needs, in one layer so the
  apt lists are discarded with it.

### `docker/Dockerfile.hindsight` — tolerant consolidation parsing
`make hindsight-patched-build` → set `HINDSIGHT_IMAGE=hindsight-patched`,
`HINDSIGHT_VERSION=local`

Applies `hindsight-tolerant-batch.patch.py`, which adds a narrow
`model_validator(mode="before")` that salvages genuine actions from a bare JSON
list and drops un-actionable rows. **This patches vendor code** and is pinned to
one upstream version — the patch script asserts every anchor and **aborts the
build** if the code shape changed, so an image bump can never silently produce
an unpatched image. A second build stage then imports the patched module in the
real venv and self-tests five cases (parroted row drops, create salvage, update
salvage, bare `id` must not become an update, object path unregressed), so a
broken patch fails at build time rather than at the first consolidation round.

The image ships neither `curl` nor `wget`, which is why both the patch step and
the compose healthcheck use its own `/app/api/.venv/bin/python3`.

---

## Long-term memory (Hindsight)

Hindsight stores memory as a knowledge graph in its embedded PostgreSQL +
pgvector. It uses an LLM for two things only — **extracting** entities from
retained content and **synthesizing** reflections — and that model is configured
separately from the one Hermes chats with. Embeddings and reranking run locally
in the container, so those make no external call.

Typical flow:

```bash
make hindsight-install     # once; persists in ./data/plugins
make hindsight-enable      # config.json + memory.provider=hindsight + restart
make hindsight-health      # network link, as seen by Hermes
make hindsight-llm-check   # Hindsight → OmniRoute → upstream, with a real call
make hindsight-roundtrip   # retain → extract → recall, model-independent
make hindsight-ui          # browse the knowledge graph
```

### Consolidation: the bare-list `ValidationError`

Consolidation (merging and deduplicating memories) asks the LLM for a strict
JSON object `{"creates":[…],"updates":[…],"deletes":[…]}`. A model that returns
a bare **list** instead fails every batch with:

```
ValidationError: 1 validation error for _ConstrainedConsolidationBatchResponse
  Input should be a valid dictionary ... input_type=list
```

This is **model-specific, not provider-wide**. `glm-5.2` (which
`auto/best-free` can route to) parrots the input facts back as a list instead of
emitting actions, while other keyless models on the same gateway return a
correct object. So consolidation is **pinned** to a specific capable model
rather than left on an `auto/*` combo that could reselect the bad one at any
time:

```
HINDSIGHT_API_CONSOLIDATION_LLM_MODEL=cfp/openai/gpt-oss-120b
# or
HINDSIGHT_API_CONSOLIDATION_LLM_MODEL=cfp/deepseek-ai/deepseek-v4-flash-0731
```

Pinning is the **first** thing to try and is not always sufficient on its own —
`deepseek-v4-flash` passes a toy `json_object` probe but can still parrot input
on Hindsight's real consolidation prompt. That is what
`docker/Dockerfile.hindsight` exists for.

There is a second failure mode in the opposite direction: a reasoning-heavy
model (e.g. `gpt-oss-120b`) spends its whole output budget thinking and gets
truncated by the playground provider's output cap:

```
non-retryable OutputTooLongError: LLM output exceeded token limits (scope=consolidation)
```

Hindsight does not cap completion tokens — the upstream does — so raising the
limit does not help. Use a low-reasoning "flash" model and keep
`..._BATCH_SIZE` small so the required JSON stays short.

---

## Inference routing (OmniRoute)

OmniRoute presents one OpenAI-compatible endpoint in front of many upstream
providers, with fallback, load balancing and token compression.

Hermes reaches it through two variables. `GTW_*` is the Hermes "tool gateway"
convention; **`CUSTOM_API_KEY` is what `model.provider = custom` actually reads
as its bearer token** (resolution order: `model.api_key` → `CUSTOM_API_KEY` →
`OPENAI_API_KEY` → `OPENROUTER_API_KEY`). Compose sets both from `GTW_API_KEY`.

Flip routing with `make provider-omniroute` / `make provider-direct` /
`make provider-free`, and confirm with `make provider-show`.

### Free / keyless combos

Two providers in this build need no credential at all (`connectionId:
"noauth"`):

- **cloudflare-playground** — drives a real browser, so the gateway image needs
  Chromium (`make omniroute-browser-build`). Slow: 30–150 s per call. **No
  structured tool calling.**
- **uncloseai** — public beta currently closed, returns HTTP 401. Nothing to do.

`OMNIROUTE_EXCLUDE_TOS_AVOID=true` keeps `tos:avoid` providers (e.g. Kiro) out
of auto routing.

---

## Observability (Langfuse)

Hindsight ships its own OTel wiring: a FastAPI instrumentor plus an OTLP/HTTP
span exporter behind a `BatchSpanProcessor`. It emits **traces only** — there is
no metrics pipeline in the image, and `OTEL_TRACES_ENABLED` is the only switch.
Langfuse likewise ingests OTLP traces and is **not** a metrics backend. If you
want real counters and gauges, put an OpenTelemetry Collector in front and fan
metrics out to Prometheus; traces keep flowing to Langfuse.

```bash
make langfuse-up            # stores → web (migrations) → worker
make langfuse-otel-header   # compute the Basic auth header into .env
docker compose up -d hindsight
make langfuse-verify        # prove Hindsight → OTLP → Langfuse → ClickHouse
make langfuse-traces        # span counts per service
```

Two details worth knowing:

- The OTLP endpoint is a **base** URL — Hindsight appends `/v1/traces` itself.
  Point it at `/api/public/otel`. Appending the suffix by hand also works;
  appending it twice does not.
- There is deliberately **no `depends_on: langfuse`** on the Hindsight service.
  The exporter retries in the background, so a Langfuse outage must not be able
  to take long-term memory down with it. Spans buffered during an outage are
  dropped once the queue fills; memory itself keeps working.

---

## Operational runbook / troubleshooting

### `make omniroute-models` returns HTTP 401
OmniRoute requires a key that exists in **its own** database, even when
`OMNIROUTE_REQUIRE_API_KEY=false`. Run `make omniroute-key`, or do it by hand:
`make gtw-dashboard` → connect an upstream provider → Endpoints → create a key →
put it in `.env` as `GTW_API_KEY` → `make restart`.

If login fails, note that `OMNIROUTE_INITIAL_PASSWORD` seeds the password on
**first boot only** — if you changed it in the dashboard, put the real one in
`.env`.

### `gateway inaccessible: unsafe_control_permissions`
Hermes refuses any control path carrying group or other bits — the check is
`mode & 0o077 == 0`, so `0775` fails it just as `0755` does:

```
/opt/data/gateway.sock has mode 0755, expected 0600
```

On macOS the virtiofs bind mount creates `gateway.sock` as `0755`. Every target
that restarts Hermes polls for the socket and re-`chmod`s it (the gateway
recreates it a few seconds **after** `docker compose restart` returns, so a
single chmod races and loses). `make fix-permissions` does it on demand.

One case cannot be repaired: `chmod()` on a **socket** returns `EINVAL` on a
Docker Desktop VirtioFS "fakeowner" bind mount. The Makefile tolerates that
failure by design.

### Plugin install fails with `Permission denied: /opt/data/installs/<id>`
The `hermes-installs` named volume must be writable by uid 1000. New images seed
this correctly, but a volume created by an older image is root-owned — `make up`
and `make fix-permissions` both repair it.

### Plugin dependency build fails on `share/terminfo/a` vs `A`
That path is on the case-insensitive macOS bind mount. It is why
`/opt/data/installs` is a named volume; make sure you have not removed that
mount from `docker-compose.yml`.

### Consolidation never runs; `pending=1`, `others: <id>:1`, no errors
A stale worker lease. Run `make hindsight-unstick`. Re-POSTing `/consolidate`
will **not** help — it returns `{"deduplicated": true}` and folds into the same
stuck task.

### Consolidation reports "0 processed" after you fixed the model
Facts marked `consolidation_failed_at` are excluded from future rounds.
`make hindsight-consolidate` POSTs `/consolidation/recover` first to re-queue
them (disable with `RECOVER=0`).

### `make hindsight-llm-check` reports `timeout`
Normal on free keyless combos: they are browser-driven, 30–150 s per call, and
the probe budget is about 10 s. It does **not** mean retain is broken — verify
with `make hindsight-roundtrip`.

### Hindsight will not start: `ValueError: LLM API key is required`
`HINDSIGHT_API_LLM_API_KEY` is empty. It only has to be non-empty at startup, so
the OmniRoute key satisfies it; compose falls back to `GTW_API_KEY` by default.

### The agent records "0 tool calls" and prints `tool_calls: [...]` as text
The model behind your route has no structured tool calling. Confirm with
`make tool-call-check`, then either switch providers or set
`HINDSIGHT_MEMORY_MODE=context` to use injection only.

### `make demo-memory` shows a tool call that never executed
Do not add `--oneshot`: it ends the turn after the first assistant message, so
the call is emitted but never run. The target uses `--max-turns 8 -q`.

### langfuse-web crash-loops on `Dirty database version 39`
Langfuse v4's ClickHouse migration `0039_create_events_full` declares full-text
indexes with named arguments, which older servers reject with `Code: 80.
DB::Exception: Only literals can be skip index arguments`. The migrator then
flags version 39 dirty and web crash-loops forever after. **25.12 accepts the
DDL; 25.4 does not** — do not downgrade `LANGFUSE_CLICKHOUSE_IMAGE` without
re-testing that migration. To recover, `make langfuse-reset`.

ClickHouse `/ping` also answers before the server finishes opening its
keeper/metadata paths, and a migration starting in that window can die partway
and leave the same dirty flag. The generous `start_period` on the ClickHouse
healthcheck is what keeps that window closed.

### langfuse-worker spins on `relation "monitors" does not exist`
It was started against an unmigrated database. The **web** image owns every
migration; the worker's entrypoint runs none. It must wait for
`langfuse-web: service_healthy`, which is how compose is wired — do not reverse
that dependency, as gating web on the worker deadlocks the stack.

### Langfuse healthchecks use `$$HOSTNAME`, not `127.0.0.1`
Next.js standalone (and the worker) bind only to the interface their `HOSTNAME`
env resolves to, and Docker sets `HOSTNAME` to the container id — so loopback
gets "Connection refused" even while the published port serves 200.

### Langfuse login redirect bounces
`LANGFUSE_NEXTAUTH_URL` must match the URL you open in the browser, not the
in-network hostname.

### A stale `./data/hindsight/config.json` overrides `.env`
The profile file wins over environment variables. Regenerate it with
`make hindsight-config` instead of editing it.

### ClickHouse logs "Too many open files"
Already handled: the service raises `nofile` to 262144, because the Docker
default of 1024 degrades it under even light ingestion.

---

## Documentation in `docs/`

| File | What |
|---|---|
| `docs/guides/DOCKER_HERMES_GUIDE.md` | Long-form guide to this Docker environment — the stack table, data-flow diagram and the reasoning behind the layout. The best companion to this README. |
| `docs/guides/hermes_docker_guide.html` | HTML rendering of the same material. |
| `docs/course/Hermes_Zero_to_Hero_v0.1_Codex.html` | "Hermes Agent · Five-Day Technical Course". |
| `docs/diagrams/hermes-stack.html` | Hermes Agent Stack Diagram. |
| `docs/diagrams/hermes-architecture.html` | Architecture guide diagram. |
| `docs/diagrams/hermes-auth-data-flow.html` | Auth and data-flow diagram. |
| `docs/diagrams/*.delivery.json` | Delivery metadata accompanying each diagram. |

---

## A note on the comments in this repo

`docker-compose.yml`, the `Makefile` and every script carry long explanatory
comments recording *why* a setting is what it is — which pinned version, which
error message it prevents, and what was verified. They are the primary source
for this README. When you change a default, update the comment next to it.
