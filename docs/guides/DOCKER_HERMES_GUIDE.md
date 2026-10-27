# Hermes Agent Docker Environment

This setup enables creating, running, managing, and destroying a complete Hermes Agent stack quickly with `make`, while mounting local host storage for state (`/opt/data`) and working files (`/workspace`).

The stack is **three services**: the agent (which also serves the web dashboard), an inference gateway, and a long-term memory server.

---

## 🧭 What's In The Stack

| Service | Container | Image | What it does |
|---|---|---|---|
| **hermes** | `hermes-agent` | built from `docker/Dockerfile` | The agent itself. Runs `gateway run`, exposes an OpenAI-compatible API, **and serves the Web UI on :9119** — s6-overlay supervises the gateway and the dashboard side by side in this one container. |
| **omniroute** | `hermes-agent-gtw` | `ghcr.io/diegosouzapw/omniroute:latest` | AI gateway. One OpenAI-compatible endpoint in front of many upstream providers, with fallback, load balancing and token compression. |
| **hindsight** | `hermes-agent-hindsight` | `ghcr.io/vectorize-io/hindsight:latest` | Self-hosted long-term memory. Knowledge graph + entity resolution + multi-strategy retrieval. Bundles its own PostgreSQL + pgvector. |

> **Why the dashboard is not its own container.** The official image is s6-overlay supervised: `gateway run` is redirected to the supervised service, which *also* starts a dashboard whenever `HERMES_DASHBOARD` is truthy (`1`, `true`, `yes`). Earlier versions of this repo ran a second container off the same image and the same `./data` bind mount — which meant **two writers against the same SQLite/WAL files** (`state.db`, `kanban.db`) and two gateway supervisors over one `gateway.sock`. One container, two supervised processes, is both the supported design and the safe one.
>
> Set `HERMES_DASHBOARD=0` in `.env` if you want the agent without the web UI.

### Data flow

```
                      ┌──────────────────────────────┐
   you ──► make chat ─┤  hermes  (hermes-agent)      │
                      │  + Web UI :9119 (s6)        │
                      └───┬──────────────────┬───────┘
         inference        │                  │   long-term memory
         /v1/chat/completions                │   /v1/default/banks/...
                          ▼                  ▼
              ┌───────────────────┐   ┌─────────────────────────┐
              │ omniroute :20128  │   │ hindsight :8888 (API)   │
              │ (AI gateway)      │◄──┤          :9999 (UI)     │
              └─────────┬─────────┘   │ embedded PostgreSQL +   │
                        │             │ pgvector, local embeds  │
                        ▼             └─────────────────────────┘
          upstream LLM providers
          (OpenAI, Anthropic, OpenRouter, ...)
```

Note the arrow from `hindsight` back to `omniroute`. Hindsight needs its **own** LLM to extract entities and synthesize reflections, and by default this stack points it at OmniRoute too. That means **one credential, configured once in the OmniRoute dashboard, powers the whole stack.** Embeddings and reranking run locally inside the Hindsight container, so those never leave your machine.

### Ports & credentials

| URL | What | Default credentials | `make` shortcut |
|---|---|---|---|
| `http://localhost:9119` | Hermes Web UI dashboard (served by the `hermes` container) | `admin` / `hermes-admin` (`DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`) | `make webui` |
| `http://localhost:20128` | OmniRoute dashboard + `/v1` gateway | password `omniroute-admin` (`OMNIROUTE_INITIAL_PASSWORD`) | `make gtw-dashboard` |
| `http://localhost:8888` | Hindsight REST API (`/health`, `/v1/default/banks/...`) | none by default (`HINDSIGHT_API_KEY` optional) | `make hindsight-health` |
| `http://localhost:9999` | Hindsight memory explorer UI | none by default | `make hindsight-ui` |
| `http://localhost:8642` | Hermes OpenAI-compatible API server | `API_SERVER_KEY`, off unless `API_SERVER_ENABLED=true` | — |

Inside the Docker network the services address each other by **service name**, not `localhost`:
`http://omniroute:20128/v1` and `http://hindsight:8888`.

---

## 🚀 Quick Start

### 1. Initialize & start the whole stack
```bash
make up
```
This creates the directories (`./data` → `/opt/data`, `./workspace` → `/workspace`, `./data-gtw` → OmniRoute), generates `.env` from `.env.example`, builds or pulls the images, and starts all three containers.

`hermes` waits for `hindsight` to report **healthy** before it starts (`depends_on: condition: service_healthy`), so the first boot takes a minute or two while Hindsight initializes its PostgreSQL.

### 2. Check that everything is actually wired up
```bash
make verify
```
This is the single most useful command in the repo. It walks the whole stack and prints real evidence for each link: container status, whether OmniRoute answers *from inside the Hermes container*, whether Hindsight answers from there too, which inference provider Hermes is using, whether the memory plugin is installed and enabled, and `hermes doctor`.

```bash
make ps        # just container status
make status    # just hermes doctor
```

### 3. Configure OmniRoute (required — nothing can call a model until you do)
See **Demo 1** below. Until you create an upstream provider connection and an API key in the OmniRoute dashboard, `make verify` will correctly report:

```text
HTTP 401
{"error":{"message":"Invalid API key","type":"invalid_api_key","code":"invalid_api_key"}}
```

That is expected on a fresh install. `GTW_API_KEY=omniroute-local` in `.env.example` is a **placeholder**, not a working key.

### 4. Enable long-term memory
See **Demo 3**. In short:
```bash
make hindsight-install   # once; persists in ./data/plugins
make hindsight-enable    # writes config + sets memory.provider + restarts
make hindsight-status
```

### 5. Interactive interfaces

- **Classic CLI chat:** `make chat` — runs `hermes chat --cli`.
- **Full-screen Ink TUI:** `make tui` — runs `hermes --tui`, with panels, mouse scrolling, live tool streaming.
- **Safe admin console (no LLM calls, no token spend):** `make console`.
- **Model & provider selector:** `make model`.
- **Hermes Web UI:** `make webui` → `http://localhost:9119` (redirects to a sign-in page; use `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`).
- **OmniRoute dashboard:** `make gtw-dashboard` → `http://localhost:20128`.
- **Hindsight memory explorer:** `make hindsight-ui` → `http://localhost:9999`.
- **Shell inside the agent:** `make shell`.

### 6. Provider & API keys for *direct* use (bypassing OmniRoute)
If you would rather not use the gateway:
```bash
make provider-direct
make setup-keys                               # interactive wizard
# or write the key yourself:
echo "OPENROUTER_API_KEY=your-key" >> ./data/.env
# or import an existing host config:
make sync-from-host
```

---

## ▶️ Demo 1: OmniRoute — one endpoint, many providers

**Goal:** make `http://omniroute:20128/v1` able to serve a real model, then prove Hermes uses it.

### Step 1 — open the dashboard
```bash
make gtw-dashboard          # http://localhost:20128
```
Log in with `omniroute-admin` (or whatever you set as `OMNIROUTE_INITIAL_PASSWORD`).

### Step 2 — connect an upstream provider
In the dashboard, add a provider connection using your own account or API key (OpenAI, Anthropic, OpenRouter, Google, and many more). This is the only place a real model credential needs to live.

Talking points for the demo:
- **Fallback tiers.** Routing falls back across four tiers — subscription, API key, cheap, free — while a healthy target remains.
- **Resilience layers.** Provider circuit breakers, per-connection cooldowns, and per-model lockouts.
- **Routing strategies.** ~20 of them: round-robin, weighted, power-of-two-choices, least-used, headroom-based. Quota-Share splits one shared account's quota fairly across pooled keys.
- **Token compression.** RTK and Caveman compression, advertised at roughly 15–95% token savings.

### Step 3 — create a client key
Go to **Dashboard → Endpoints** and create an API key. Copy it.

This step is not optional and not skippable. **OmniRoute rejects any key that does not exist in its own database, even with `OMNIROUTE_REQUIRE_API_KEY=false`.** (That env var does not disable client-key checking on `/v1`.)

### Step 4 — give the key to the stack
```bash
# edit .env and replace the placeholder
GTW_API_KEY=<the key you copied>

make restart
```
Both Hermes **and** Hindsight read `GTW_API_KEY`, so this one edit fixes both.

### Step 5 — prove it from inside the Hermes container
```bash
make omniroute-models
```
Before: `HTTP 401 {"error":{"message":"Invalid API key",...}}`
After: `HTTP 200` and a JSON list of the models OmniRoute now serves.

### Step 6 — point Hermes at the gateway and pick a served model
```bash
make provider-omniroute     # model.provider=custom, base_url=http://omniroute:20128/v1
make provider-show
make model                  # choose a model OmniRoute actually serves
make chat
```

`make provider-show` prints the live truth:
```text
model.provider : custom
model.base_url : http://omniroute:20128/v1
model.default  : anthropic/claude-opus-4.6
```

> ⚠️ `model.default` must be a model OmniRoute actually serves. A model name your gateway has no upstream for will fail at request time, not at config time.

### Flipping back and forth
```bash
make provider-omniroute    # route through the gateway
make provider-direct       # straight to OpenRouter, bypassing the gateway
make provider-show         # which am I on right now?
make gtw-logs              # watch the gateway handle requests live
```

Under the hood, `provider-omniroute` sets Hermes' `model.provider` to `custom` (Hermes' name for "any OpenAI-compatible endpoint") and `model.base_url` to the service URL. The bearer token Hermes sends is resolved in this order:

```
model.api_key (config.yaml)  →  CUSTOM_API_KEY  →  OPENAI_API_KEY  →  OPENROUTER_API_KEY
```

`docker-compose.yml` sets `CUSTOM_API_KEY=${GTW_API_KEY}`, which is why putting the key in `.env` is enough.

---

## ▶️ Demo 5b: Free combos — a working stack with zero credentials

OmniRoute can serve real completions with **no provider API key at all**, using built-in keyless (`noauth`) providers. This is what makes the course runnable for everyone. It also has hard limits you must know before you build a demo on it.

### What a "combo" is

`auto/*` model IDs are OmniRoute **routing chains**, not models. The grammar:

| Model ID | Meaning |
|---|---|
| `auto` | Zero-config routing across all connected targets (LKGP strategy, balanced weights). Does not use saved combos. |
| `auto/<variant>` | A weight profile: `coding`, `fast`, `cheap`, `offline`, `smart`, `lkgp`, `chaos`. |
| `auto/<category>:<tier>` | Category (`coding`, `reasoning`, `vision`, `chat`, `multimodal`) + tier (`fast`, `cheap`, `reliable`, `free`, `pro`). |
| `my-combo` or `combo/my-combo` | A persisted combo you created (Settings → Combos, or `POST /api/combos`). |

This gateway advertises exactly two free routing IDs: **`auto/best-free`** and **`auto/coding:free`**.

> ⚠️ **Tier filtering is fail-open.** If no connected model matches `:free`, OmniRoute uses the **full** pool. A `:free` model string is a *preference*, not a cost guarantee. Pair it with "Settings → Routing → Hide paid models" if you need a hard boundary.

### Step 1 — build the browser-enabled gateway image (required)

The biggest keyless provider, `cloudflare-playground`, drives a real browser. The published image ships the `playwright` npm package but **not** Chromium, so every free request fails with:

```text
Cloudflare Playground needs Playwright and its Chromium browser.
Install the browser runtime ... or use an OmniRoute browser-enabled deployment. (HTTP 503)
```

No browser-enabled tag is published upstream (I checked all 100 tags). So build the thin derived layer:

```bash
make omniroute-browser-build       # docker/Dockerfile.omniroute, adds Chromium + deps
# then in .env:
OMNIROUTE_IMAGE=omniroute-browser:local
docker compose up -d omniroute
```

### Step 2 — mint a gateway client key (no browser needed)

```bash
make omniroute-key
```
This logs into OmniRoute's own admin API with `OMNIROUTE_INITIAL_PASSWORD`, creates a key, verifies it against `/v1/models`, and writes it to `.env` as `GTW_API_KEY` (backing up `.env` first; the value is never printed).

It is careful about one trap: `GET /api/keys` returns **masked** key values when `allowKeyReveal` is false (the default), so a key read back from the listing is a truncated prefix that 401s. The script verifies any key before accepting it and mints a fresh one otherwise.

### Step 3 — see what is actually reachable, then prove it

```bash
make free-combos
```
```text
=== Keyless candidate pool (no credential required) ===
  channel: auto/chat | candidates: 21
  by provider: {'cloudflare-playground': 20, 'uncloseai': 1}
  keyless(noauth): 21 | reachable: 21 | excluded: 0
     cfp/zai-org/glm-5.2
     cfp/moonshotai/kimi-k2.7-code
     cfp/deepseek-ai/deepseek-v4-pro-0813
     cfp/openai/gpt-oss-120b
     ... and 13 more

=== Free model IDs this gateway advertises ===
  total models: 465
  free routing IDs: auto/best-free, auto/coding:free
```

```bash
make free-combo-test
```
```text
=== Real completion through model=auto/best-free ===
  served by: zai-org/glm-5.2
  content: 'OK'
  usage: {'prompt_tokens': 67, 'completion_tokens': 27, 'total_tokens': 94, 'cached_tokens': 0}
```

Note `uncloseai` is keyless but its public beta is **closed** and returns `HTTP 401: The public beta is closed for now`. Nothing to fix; `cloudflare-playground` carries the pool.

### Step 4 — point Hermes *and* Hindsight at the free combo

```bash
make provider-free
```
Sets `model.provider=custom`, `model.base_url=http://omniroute:20128/v1`, `model.default=auto/best-free`, and recreates both services so Hindsight picks up `HINDSIGHT_API_LLM_MODEL`.

Verify both legs:
```bash
make provider-show
# model.provider : custom
# model.base_url : http://omniroute:20128/v1
# model.default  : auto/best-free

make hindsight-llm-check
# {"bank_id":"hermes-course","operations":[
#   {"operation":"retain","ok":true,"status":"connected","latency_ms":4672.8},
#   {"operation":"consolidation","ok":true,"status":"connected","latency_ms":4672.8},
#   {"operation":"reflect","ok":true,"status":"connected","latency_ms":4672.8}]}
```
`"ok":true,"status":"connected"` on all three means Hindsight's extraction LLM now works through the free combo — no credential anywhere in the stack.

### What free combos CAN and CANNOT do

This is the most important table in this guide. Everything here was measured, not assumed.

| Capability | Free keyless combo | Notes |
|---|---|---|
| Plain chat completions | ✅ works | `make free-combo-test` returns real content and token usage. |
| Serving Hermes inference | ✅ works | Real turns complete; logs show `· OmniRoute`. |
| Hindsight entity extraction (retain) | ✅ works | `make hindsight-roundtrip` passes; canary recalled at rank 1. |
| Hindsight **consolidation** | ❌ **does not work** | Needs structured output; free provider ignores `response_format`. Disabled by default. |
| Hindsight retain → knowledge graph | ✅ works | Bank populated, correct entities extracted. |
| Hindsight auto-recall + context injection | ✅ works | Hindsight logs `Complete: 16 facts (590 tok) | world=16 | 0.261s`. |
| **Structured tool calling** | ❌ **does not work** | No `tool_calls` field is ever returned. |
| `hindsight_recall` / `retain` / `reflect` **tools** | ❌ cannot execute | Depend on tool calling. |
| Agent reliably *using* injected memory | ❌ unreliable | Models tested ignored injected facts and/or hit `finish_reason='length'`. |

Check any model yourself:
```bash
make tool-call-check
```
```text
=== Structured tool-calling probe: model=auto/best-free ===
  served by: zai-org/glm-5.2
  RESULT: NO structured tool_calls field.
  => Hermes will record 0 tool calls. Use HINDSIGHT_MEMORY_MODE=context
     (injection only) on this model, and switch to a provider with real
     function calling for any tool-using demo.
```

> ⚠️ **`/v1/models` lies about this.** OmniRoute advertises `"capabilities":{"tool_calling":true}` on `auto/*` entries. That is combo-level metadata, not a promise the keyless upstream honours. Trust `make tool-call-check`, not the catalog.

Because of this, the shipped default is `HINDSIGHT_MEMORY_MODE=context` (injection only). Tools would be advertised to the model and silently never execute. **Switch to `hybrid` once you connect a provider with real function calling**, then re-run `make hindsight-enable`.

### Bottom line for the course

Free combos are excellent for proving the plumbing end to end, smoke-testing, and plain chat — at zero cost and zero signup. For the **memory recall demo**, or anything tool-using, connect a real provider in the OmniRoute dashboard (Demo 5) and set `HINDSIGHT_MEMORY_MODE=hybrid`. One upstream key makes the whole stack behave.

---

## ▶️ Demo 2: Hermes interfaces

```bash
make chat       # classic REPL
make tui        # full-screen Ink TUI
make console    # admin console; inspects status/skills/cron with no LLM calls
make webui      # browser dashboard at :9119 (admin / hermes-admin)
```

Good demo beats:
1. `make console` first — it costs nothing and shows the agent's internal state.
2. `make tui` to show live tool-call streaming.
3. `make webui` to show the same `/opt/data` state rendered in a browser — served by the **same** container as the agent, so there is only ever one writer against `state.db`.

---

## ▶️ Demo 3: Hindsight — long-term memory that survives the session

**Goal:** teach the agent a fact in one session, then recall it in a brand-new session, then look at the knowledge graph it built.

### Step 1 — install the plugin (once)
```bash
make hindsight-install
```
This runs `hermes plugins install hindsight --ref d952b6e6... --yes-deps --enable`, pinned to an immutable commit SHA. Expected output:

```text
╭──────────── ✓ Installed ────────────╮
│ Plugin installed: ...               │
│ Location: /opt/data/plugins/hindsight │
╰─────────────────────────────────────╯
  → Resolving Python dependencies…
  ✓ Resolving Python dependencies
  → Installing Python dependencies…
  ✓ Installing Python dependencies
✓ hindsight set as memory.provider.
```

Because `/opt/data` is the `./data` bind mount, the plugin lands in `./data/plugins/hindsight` **on your Mac** and survives `make down`, `make up`, `--force-recreate` and image rebuilds. Only `make destroy` removes it. This is also why the plugin is *not* baked into the Dockerfile — anything the image writes under `/opt/data` is shadowed by the bind mount at runtime and would be invisible to the agent.

### Step 2 — write the config from `.env`
```bash
make hindsight-config
```
This generates `./data/hindsight/config.json` from your `.env` values and **backs up any existing file** with a timestamp:

```text
Backed up existing config to ./data/hindsight/config.json.bak-20261025153413
Wrote ./data/hindsight/config.json:
{
  "mode": "local_external",
  "api_url": "http://hindsight:8888",
  "bank_id": "hermes-course",
  "timeout": 120,
  "memory_mode": "hybrid",
  "recall_budget": "mid",
  "recall_types": "observation,world,experience",
  "auto_retain": true
}
```

Generate it rather than hand-editing it. The plugin resolves config in the order **profile file → `~/.hindsight/config.json` → `HINDSIGHT_*` env vars**, so the profile file *wins*. A stale `config.json` silently overrides everything in `.env` — which is exactly how a demo ends up quietly talking to the wrong server.

### Step 3 — activate it
```bash
make hindsight-enable     # runs hindsight-config, sets memory.provider, restarts hermes
make hindsight-status
```
Expected:
```text
Memory status
────────────────────────────────────────
  Built-in (MEMORY.md / USER.md):
    Memory injection:   enabled ✓
    User profile:       enabled ✓
    Memory tool:        enabled ✓
  Provider:  hindsight

  Plugin:    installed ✓
  Status:    available ✓

  Installed plugins:
    • byterover  (API key / local)
    • retaindb  (API key / local)
    • hindsight  (API key / local) ← active
```
And `make status` (`hermes doctor`) reports `✓ hindsight provider active`.

Only one external provider can be active at a time. Hermes' **built-in** memory (`MEMORY.md` / `USER.md`) is always active regardless.

### Step 4 — prove the network link
```bash
make hindsight-health
```
```text
--- hindsight /health/ready as seen BY HERMES ---
{"status":"healthy","database":"connected","db_acquire_ms":0.4,"db_pool_waiting":0,
 "db_pool_in_use":0,"db_pool_max":100,"db_pool_idle":5}
```
The point of running this *inside* the Hermes container is that it tests the path the agent actually uses, not the host port mapping.

```bash
make hindsight-llm-check    # does Hindsight's own LLM work? (needs Demo 1 done)
make hindsight-banks        # which memory banks exist?
```

### Step 5 — retain, then recall in a fresh session
```bash
make demo-memory
```
Or by hand, to control the narrative:

```bash
# Session A — teach it something it cannot possibly infer
make chat
> Remember this for later: our staging database rotates credentials every
  Tuesday at 03:00 UTC, and Priya owns the rotation runbook.
> /exit

# Session B — brand new context, no history
make chat
> Who owns the staging credential rotation runbook, and when does it run?
```

> ⚠️ **On a free keyless combo this last step is unreliable.** Retain, extraction and auto-recall all work (Hindsight logs `Complete: 16 facts (590 tok) | world=16 | 0.261s`), but the free models tested ignored the injected facts and answered "I don't have that information", and one hit `finish_reason='length'` mid-reasoning. For a demo that lands every time, connect a real provider (Demo 5) and set `HINDSIGHT_MEMORY_MODE=hybrid`. See Demo 5b for the full capability matrix.
>
> To check the memory itself rather than the model, query Hindsight directly — this is the honest proof that retain worked:
> ```bash
> docker exec hermes-agent curl -s -X POST \
>   http://hindsight:8888/v1/default/banks/hermes-course/memories/recall \
>   -H 'Content-Type: application/json' \
>   -d '{"query":"Which ports do OmniRoute and Hindsight use?","budget":"mid"}'
> ```

When the model cooperates, three things are happening:
- **`auto_retain`** captures each turn automatically (async by default).
- **`memory_mode: hybrid`** both injects recalled context *and* exposes tools.
- The tools are **`hindsight_retain`** (store, with entity extraction), **`hindsight_recall`** (multi-strategy search over semantics + the entity graph), and **`hindsight_reflect`** (LLM synthesis across memories).

Say "use your memory tool to retain this" in session A if you want to force an explicit, visible tool call rather than relying on automatic capture.

### Step 6 — inspect the knowledge graph
```bash
make hindsight-ui          # http://localhost:9999
```
Browse entities, relationships and documents. Note that `recall_types` defaults to `observation` only, which hides raw facts; `make hindsight-config` sets it to `observation,world,experience` so the demo shows everything.

The REST API is worth showing too:
```bash
docker exec hermes-agent curl -s http://hindsight:8888/v1/default/banks
docker exec hermes-agent curl -s http://hindsight:8888/v1/default/banks/hermes-course/entities
docker exec hermes-agent curl -s http://hindsight:8888/v1/default/banks/hermes-course/graph
```
A bank only appears **after the first retain** — an empty `{"banks":[],"total":0,...}` on a fresh stack is correct, not a fault.

### Step 7 — turn it off
```bash
make hindsight-disable     # built-in MEMORY.md / USER.md stays active
```

---

## 🔐 The three Hindsight modes, and the privacy trade-off

Set `HINDSIGHT_MODE` in `.env`, then re-run `make hindsight-enable`.

| Mode | Where memory lives | Needs | Use when |
|---|---|---|---|
| `local_external` **(this stack's default)** | the `hindsight` container, on your machine | the compose service | You want a fully local demo you can inspect. |
| `cloud` | Vectorize's hosted service | `HINDSIGHT_API_KEY`, `HINDSIGHT_API_URL=https://api.hindsight.vectorize.io` | You want zero ops and don't mind the data leaving. |
| `local_embedded` | a daemon Hermes starts itself, inside the Hermes container | nothing (fetched with `uvx`, version-pinned, on first use) | No separate service; you accept a cold-start and an idle timeout. |

**Read this out loud during the demo.** The plugin's own disclosure, verbatim from `hermes plugins info hindsight`:

> Disclosure — in cloud mode (and local external) every turn's conversation, and every entry the agent adds or replaces in Hermes's built-in MEMORY/USER stores, is sent to `api.hindsight.vectorize.io` **or the URL you configure**, into every bank it writes to; local embedded mode starts a background Hindsight daemon (fetched with `uvx`, version-pinned, on first run when `hindsight-api` is not installed) and keeps its LLM settings in `~/.hindsight/profiles/<profile>.env`; setup writes the keys you enter to the profile `.env`; repositories under folders you list in `trusted_project_dirs` may choose their bank with `.hindsight/config.toml`.

So: `local_external` is **not** automatically private — it is private *because* the URL you configured is a container on your own machine. Point `HINDSIGHT_API_URL` at a remote host and every turn goes there instead. Check which one you are on before demoing with real data:

```bash
cat ./data/hindsight/config.json
```

One more honest caveat even in the fully local setup: Hindsight's **entity extraction and reflection** call out to whatever `HINDSIGHT_API_LLM_BASE_URL` points at. In this stack that is OmniRoute, which then calls a real upstream provider. Embeddings and reranking are local; the extraction prompts are not. Set `HINDSIGHT_API_LLM_PROVIDER=ollama` (or `lmstudio`) with a local base URL if you need the whole path to stay on your machine.

Also worth stating: `hermes memory setup` fetches its bank-template catalog from `raw.githubusercontent.com`, so that wizard needs network access.

---

## 📁 Storage & Adding/Removing Files Locally

| Host path | Container path | Holds |
|---|---|---|
| `./data` | `/opt/data` | `config.yaml`, `.env`, `memories/`, `skills/`, `plugins/`, `hindsight/config.json`, `profiles/`, logs, `state.db` |
| `./workspace` | `/workspace` | Your repos, documents, datasets, scripts |
| `./data-gtw` | `/app/data` | OmniRoute's `storage.sqlite` (provider connections, API keys, usage) |
| named volume `hindsight-pgdata` | `/home/hindsight/.pg0` | Hindsight's PostgreSQL data |
| named volume `hermes-installs` | `/opt/data/installs` | Plugin Python dependency environments |

### Why two named volumes instead of bind mounts

These two are deliberately **not** on the host, and both reasons are macOS-specific:

1. **`hermes-installs`** — the macOS bind mount (virtiofs) is **case-insensitive**. Hermes copies a Python toolchain into this directory, and that toolchain contains both `share/terminfo/a` and `share/terminfo/A` (likewise `e/E`, `l/L`, `m/M`, `n/N`, `p/P`, `q/Q`, `x/X`). On a case-insensitive filesystem those collide and the dependency build fails. A named volume is ext4 inside the Docker VM, so it is case-sensitive and the problem disappears. See Diagnostics §5.
2. **`hindsight-pgdata`** — PostgreSQL on a virtiofs bind mount is slow and its fsync semantics are not trustworthy. Set `HINDSIGHT_DATA_VOLUME=./data-hindsight` in `.env` if you want it on the host anyway; the compose file accepts either a volume name or a path.

Inspect them with:
```bash
docker volume ls | grep hermes-course
docker run --rm -v hermes-course_hindsight-pgdata:/d alpine ls -la /d
```

### Syncing with host `~/.hermes`
```bash
make sync-from-host   # ~/.hermes  -> ./data
make sync-to-host     # ./data -> ~/.hermes (timestamped backup made first)
```

---

## 🎭 Profiles Management

Hermes supports multiple isolated profiles (separate memory, persona, skills, config):

```bash
make profile-list
make profile-create NAME=dev-bot
make profile-create NAME=ops CLONE=1     # clone default config & skills
make profile-use NAME=ops
```

Profiles interact with Hindsight: `bank_id_template` can derive the memory bank name from `{profile}`, `{workspace}`, `{project}`, `{platform}`, `{user}` or `{session}`, so each profile can get its own bank. This stack pins a single static `bank_id` (`hermes-course`) instead, because one shared bank makes the retain-then-recall demo easier to follow. Switch to `"bank_id_template": "hermes-{profile}"` in `./data/hindsight/config.json` if you want per-profile isolation.

---

## 🤖 Messaging Bots & Gateway

```bash
make bot-setup    # interactive wizard (Telegram, Discord, Slack, WhatsApp, 20+)
make bot-start    # start or restart the messaging gateway
make bot-logs     # tail gateway logs
```

---

## 🛑 Lifecycle & Teardown

```bash
make down            # stop and remove containers
make restart         # down + up
make update-image    # docker compose pull + force-recreate
make clean           # down --remove-orphans -v (keeps ./data)
make destroy         # ⚠️ wipes containers, images AND ./data + ./workspace
```

`make destroy` prompts for confirmation. It deletes the installed Hindsight plugin, all memories, profiles and `state.db`. Run `make hindsight-install` again after a destroy.

Per-service logs:
```bash
make logs            # hermes
make gtw-logs        # omniroute
make hindsight-logs  # hindsight
```

---

## 🩺 Diagnostics & Doctor Fixes

### 1. Configure missing API keys (`hermes setup`)
```bash
make setup-keys
```
Interactive wizard inside the container for model keys (OpenAI, Anthropic, Perplexity, Nous Portal, …). You can also write keys directly to `./data/.env`.

### 2. NPM vulnerability warnings in root, web & ui-tui
- **Cause:** node packages baked at Docker build time from the upstream lockfile. `/opt/hermes` is sealed and immutable.
- **Fix:** do *not* run `npm audit fix` inside the container — it does not persist. Wait for the upstream lockfile patch, then `make update-image`.

### 3. Avoiding duplicate bot tokens across cloned profiles
`make profile-create NAME=ops CLONE=1` automatically unsets `TELEGRAM_BOT_TOKEN` and `API_SERVER_ENABLED` in the clone so it does not collide with the default profile's gateway adapter.

### 4. `unsafe_control_permissions` on `gateway.sock`
```text
Error: Gateway inaccessible: unsafe_control_permissions
(/opt/data/gateway.sock has mode 0755, expected 0600; chmod 600 /opt/data/gateway.sock)
```
- **Why:** macOS bind mounts (virtiofs) default to `0755`. Hermes requires `gateway.sock` to be `0600`.
- **Fix:** the relevant `make` targets already do this for you. Otherwise:
  ```bash
  make fix-permissions
  # or: chmod 600 ./data/gateway.sock
  ```

### 5. Plugin install fails with `File exists: .../share/terminfo/A`
```text
✗ Could not prepare hindsight's dependencies:
[('/opt/hermes/tools/python-.../share/terminfo/q',
  '/opt/data/installs/.../share/terminfo/q', "[Errno 17] File exists: ...")]
```
- **Why:** the macOS bind mount is **case-insensitive**. The Python toolchain Hermes copies into `/opt/data/installs` contains both `terminfo/a` and `terminfo/A`; on a case-insensitive filesystem the second one collides with the first.
- **Confirm it:**
  ```bash
  docker exec hermes-agent sh -c 'cd /opt/data && mkdir -p ct && cd ct && mkdir a && mkdir A'
  # mkdir: cannot create directory 'A': File exists   <- case-insensitive
  ```
- **Fix:** already handled — `docker-compose.yml` mounts the `hermes-installs` named volume at `/opt/data/installs`, which is case-sensitive ext4. If you hit this, you are probably on an older compose file; `make down && make up`.

### 6. Plugin install fails with `Permission denied: /opt/data/installs/<id>`
- **Why:** Docker seeds a new named volume from the image's mountpoint, *including its owner and mode*. If `/opt/data/installs` does not exist in the image, Docker creates it `root:root 0755`, and the Hermes worker (uid 1000, `hermes`) cannot write there.
- **Fix:** `docker/Dockerfile` now creates `/opt/data/installs` owned by `1000:1000`, and `make up` / `make fix-permissions` repair pre-existing volumes:
  ```bash
  make fix-permissions
  ```

### 7. Hindsight container restarts in a loop
```text
ValueError: LLM API key is required. Set HINDSIGHT_API_LLM_API_KEY environment variable.
```
- **Why:** Hindsight **refuses to boot** with an empty LLM API key. It only checks that the value is non-empty at startup, not that it works.
- **Fix:** ensure `GTW_API_KEY` is set (the compose file falls back to it, then to `omniroute-local`), or set `HINDSIGHT_API_LLM_API_KEY` explicitly in `.env`. Then:
  ```bash
  make hindsight-logs      # confirm the traceback is gone
  docker compose up -d hindsight
  ```

### 8. OmniRoute returns `401 Invalid API key`
```text
HTTP 401
{"error":{"message":"Invalid API key","type":"invalid_api_key","code":"invalid_api_key"}}
```
- **Why:** OmniRoute only accepts keys that exist in its own `storage.sqlite`. `OMNIROUTE_REQUIRE_API_KEY=false` does **not** disable this check on `/v1`, and the shipped `GTW_API_KEY=omniroute-local` is a placeholder.
- **Fix:** Demo 1, steps 1–4. Create a provider connection and a key in the dashboard, put the key in `.env` as `GTW_API_KEY`, `make restart`.
- **Knock-on effect:** Hindsight's extraction LLM goes through OmniRoute too, so until this is fixed `make hindsight-llm-check` reports:
  ```json
  {"bank_id":"hermes-course","operations":[
    {"operation":"retain","ok":false,"status":"auth_failed","latency_ms":34.6},
    {"operation":"consolidation","ok":false,"status":"auth_failed","latency_ms":34.6},
    {"operation":"reflect","ok":false,"status":"auth_failed","latency_ms":34.6}]}
  ```
  `auth_failed` with a real latency is good news in one narrow sense: the network path works and only the credential is wrong. A connection error would look different.

### 9. `make verify` says `cannot attach stdin to a TTY-enabled container`
Harmless if you see it from an older Makefile: `make status` uses `docker exec -it`, which needs a terminal. `make verify` now calls `hermes doctor` without `-it` so it works in pipes and CI.

### 10. Two `hermes-agent*` containers running, or a stale `hermes-agent-dashboard`
If you upgraded from an older compose file you may still have a separate dashboard container. It shares `./data` with the agent, so both processes write the same `state.db` / `kanban.db` WAL files and both supervise one `gateway.sock`.
```bash
docker compose up -d --remove-orphans     # removes the obsolete container
docker compose ps                         # expect exactly 3: hermes, omniroute, hindsight
docker ps -a --filter ancestor=hermes-agent-local:latest --format '{{.Names}}\t{{.Status}}'
```
The dashboard now runs inside `hermes-agent` itself. Confirm it:
```bash
docker compose logs hermes | grep -i dashboard
# s6-rc: info: service dashboard successfully started
# HERMES_DASHBOARD_READY port=9119
```

### 11. Dashboard returns `302` instead of `200`
That is correct. A non-loopback bind engages the auth gate, so `/` redirects to `/login?next=%2F`, which serves `200` with the *Sign in — Hermes Agent* page. Log in with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`.

Note that `HERMES_DASHBOARD_INSECURE` is **accepted but ignored** since the June 2026 hardening — it no longer disables the gate. A public dashboard always requires an auth provider: basic auth (`HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `_PASSWORD`, which this compose file sets) or OAuth (`HERMES_DASHBOARD_OAUTH_CLIENT_ID`). If neither is set the server **fails closed** and the dashboard will not start at all.

### 13. Free combos all fail with `needs Playwright and its Chromium browser` (HTTP 503)
The keyless `cloudflare-playground` provider drives a real browser and the published image has the `playwright` npm package but no Chromium binary.
```bash
make omniroute-browser-build
# then set in .env:  OMNIROUTE_IMAGE=omniroute-browser:local
docker compose up -d omniroute
docker exec hermes-agent-gtw ls /ms-playwright
# chromium-1234  chromium_headless_shell-1234  ffmpeg-1011
```
Building it needs one non-obvious detail: `npx playwright install` **fails with exit 127** in that image (the bundled `playwright` package declares `bin -> cli.js` but the file is absent and there is no `node_modules/.bin/playwright`). `docker/Dockerfile.omniroute` calls `node /app/node_modules/playwright-core/cli.js install --with-deps chromium` instead.

### 14. `GTW_API_KEY` written from the dashboard listing still 401s
`GET /api/keys` returns **masked** key values when `allowKeyReveal` is false (the default) — typically a ~16-character prefix instead of the real ~35-character key. Anything read back from the listing will 401. `make omniroute-key` verifies every key against `/v1/models` before writing it and mints a fresh one when the listed value is masked.

### 15. `0 tool calls` — the agent "calls" a tool but nothing happens
Two independent causes, both real:

1. **`--oneshot` ends the turn after the first assistant message**, so a tool call is emitted and never executed. Use `--max-turns N` instead. (`--oneshot` is also *implied on non-TTY stdio*, which is why `docker exec` without `-t` behaves this way even if you omit the flag.)
2. **The model has no structured tool calling.** On free keyless combos the call leaks into the message body as plain text:
   ```text
   tool_calls: [{"name": "hindsight_recall", "arguments": "{\"topic\": \"...\"}"}]
   ```
   Confirm with `make tool-call-check`. `model.streaming: false` does **not** fix this — that escape hatch is for servers whose *streaming* tool-call path is broken, whereas these providers return no `tool_calls` field at all. Use `HINDSIGHT_MEMORY_MODE=context`, or connect a provider with real function calling.

### 16. `unsafe_control_permissions` immediately after a restart
The gateway recreates `gateway.sock` a few **seconds after** `docker compose restart` returns, so a single `chmod` right after a restart races and loses. Every Makefile target that restarts Hermes now polls for the socket (`WAIT_SOCK`) instead of chmod-ing once. If you restart by hand:
```bash
docker compose restart hermes
for i in $(seq 1 40); do [ -e ./data/gateway.sock ] && chmod 600 ./data/gateway.sock && break; sleep 2; done
```

### 17. The agent's own hallucination gets stored as a memory
`auto_retain` captures **every** turn, including wrong assistant answers. A real example from this repo: after the agent guessed ports 8001/8002, a later recall returned its guess ranked *above* the truth:
```text
- OmniRoute uses port 8002 | When: 2026-10-25T19:06:10+00:00   <- hallucination, retained
- Hindsight uses port 8001 | When: 2026-10-25T19:06:10+00:00   <- hallucination, retained
- The hermes-course demo stack uses Hindsight on port 8888.    <- truth
- The hermes-course demo stack uses OmniRoute on port 20128.   <- truth
```
This is memory poisoning, and it is worth demonstrating deliberately. Mitigations: set `HINDSIGHT_AUTO_RETAIN=false` and retain explicitly; scope what is captured with `HINDSIGHT_RETAIN_OBSERVATION_SCOPES` / `HINDSIGHT_RETAIN_SOURCE`; or prune in the explorer UI (`make hindsight-ui`). Use a fresh `HINDSIGHT_BANK_ID` for each demo run so a bad run does not contaminate the next.

### 19. `ValidationError ... _ConstrainedConsolidationBatchResponse`
```text
ValidationError: 1 validation error for _ConstrainedConsolidationBatchResponse
  Input should be a valid dictionary or instance of _ConstrainedConsolidationBatchResponse
  [type=model_type, input_value=[{'fact_id': '96656ce0-f4...', 'category': 'monitoring'}], input_type=list]
```

**What it is.** Consolidation (the pass that merges and dedupes memories) asks the LLM for a strict JSON **object** `{"creates":[...],"updates":[...],"deletes":[...]}` (`consolidator.py:852`). The model returned a bare **list**, so Pydantic rejects the whole batch. The entries carry `fact_id` / `category`, which are **not fields of any action model** — the action models key on `observation_id` (`_UpdateAction`, `_DeleteAction`) or carry no id at all (`_CreateAction`). The model is *parroting the input facts back* instead of emitting actions.

**Root cause: it is MODEL-specific, not provider-wide.** This is the key finding. `auto/best-free` routes to `glm-5.2`, which parrots input. Other **keyless** models on the same gateway return a correct object. Probed with a `json_object` request:

| Keyless model | Returns a correct object? |
|---|---|
| `cfp/zai-org/glm-5.2` (what `auto/best-free` picks) | ❌ bare list / prose |
| `cfp/openai/gpt-oss-120b` | ✅ yes |
| `cfp/deepseek-ai/deepseek-v4-flash-0731` | ✅ yes |
| `cfp/zai-org/glm-4.7-flash` | ✅ yes |
| `cfp/moonshotai/kimi-k2.6` | ✅ yes |

**The fix: pin consolidation to its own capable model.** Consolidation has a full set of per-operation LLM settings, so it need not share the chat model:

```bash
HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION=true
HINDSIGHT_API_CONSOLIDATION_LLM_PROVIDER=openai
HINDSIGHT_API_CONSOLIDATION_LLM_BASE_URL=http://omniroute:20128/v1
HINDSIGHT_API_CONSOLIDATION_LLM_API_KEY=            # blank = reuse GTW_API_KEY
HINDSIGHT_API_CONSOLIDATION_LLM_MODEL=cfp/deepseek-ai/deepseek-v4-flash-0731
HINDSIGHT_API_CONSOLIDATION_LLM_REASONING_EFFORT=low
HINDSIGHT_API_CONSOLIDATION_LLM_BATCH_SIZE=2
```
Pin a **specific** model, not an `auto/*` combo — a combo can reselect `glm-5.2` on any request, so the error would return intermittently.

Verify with:
```bash
make hindsight-consolidate
```

**Pinning a model is necessary but NOT sufficient.** `cfp/deepseek-ai/deepseek-v4-flash-0731` passes a toy `json_object` probe, yet on Hindsight's *real* consolidation prompt it still parrots input — **28 further ValidationErrors** with `created=0 updated=0 failed=1` on every batch. The toy probe was simply not representative of a large prompt carrying the full creates/updates/deletes schema with enum-constrained `source_fact_ids`. So the model pin fixes `OutputTooLongError` but not the shape error.

**The actual fix: tolerant parsing.** A locally built image adds a narrow `model_validator(mode="before")` to `_ConsolidationBatchResponse` (the base class, so `_ConstrainedConsolidationBatchResponse` inherits it) which coerces a bare list:

```bash
make hindsight-patched-build
# then in .env:
HINDSIGHT_IMAGE=hindsight-patched
HINDSIGHT_VERSION=local
docker compose up -d hindsight
make hindsight-consolidate
```

Two deliberately conservative rules, both covered by build-time assertions:

| Input row | Treated as | Why |
|---|---|---|
| has usable `text` + explicit `observation_id` | **update** | the model named a target explicitly |
| has usable `text`, no `observation_id` | **create** | non-destructive; discarded downstream if it cites no batch fact |
| no usable `text` (e.g. `{"id": ..., "created_at": ...}`) | **dropped** | parroted input; no defensible action exists |

A bare `id` is **never** mapped onto `observation_id`. In parroted output `id` is a *fact* id, and treating it as an *observation* id would rewrite the wrong record.

> ⚠️ **This patches vendor code and is pinned to one upstream version.** `docker/hindsight-tolerant-batch.patch.py` asserts every anchor (the pydantic import line and the exact class body) and **aborts the build** if upstream changed shape, so an image bump can never silently yield an unpatched image. The Dockerfile then runs a five-case self-test inside the real venv, so a broken patch fails at build time rather than at the first consolidation round:
> ```text
> #8 2.196 patch self-test OK
> ```
> On a Hindsight image bump, re-check `docker/hindsight-tolerant-batch.patch.py` and rebuild. To go back to stock, set `HINDSIGHT_IMAGE=ghcr.io/vectorize-io/hindsight` and `HINDSIGHT_VERSION=latest`.

**A third trap: after fixing the cause, consolidation reports `completed: 0 processed`.** Facts that a failed round marked `consolidation_failed_at` are **excluded from all future rounds**, so a plain `/consolidate` finds nothing and looks healthy while nothing happens. Re-queue them:
```bash
docker exec hermes-agent curl -s -X POST \
  http://hindsight:8888/v1/default/banks/hermes-course/consolidation/recover \
  -H 'Content-Type: application/json' -d '{}'
# {"retried_count":5}
```
`make hindsight-consolidate` now does this automatically (pass `RECOVER=0` to skip).

**Two traps on the way to that fix, both found the hard way:**

1. **`HINDSIGHT_API_ENABLE_AUTO_CONSOLIDATION=false` does NOT stop consolidation.** It only suppresses the *inline post-retain* trigger. A background worker poller keeps claiming queued consolidation tasks:
   ```text
   Worker 36bd02904b43 claimed 1 tasks (1 consolidation): consolidation:1 (schemas: default)
   ```
   Measured with the flag set to `false` in the running container: **30 consolidation runs and 24 ValidationErrors**. Disabling it is not a fix and not even a reliable workaround.

2. **A reasoning-heavy model swaps one error for another.** `cfp/openai/gpt-oss-120b` produces the right *shape* but spends its whole output budget thinking and gets truncated:
   ```text
   non-retryable OutputTooLongError: LLM output exceeded token limits
   (openai/cfp/openai/gpt-oss-120b, scope=consolidation).
   Input may need to be split into smaller chunks.
   ```
   Raising the cap does not help — `DEFAULT_CONSOLIDATION_MAX_COMPLETION_TOKENS` is `None`, so Hindsight is not the one capping it; the upstream playground is. Use a low-reasoning *flash* model and keep `CONSOLIDATION_LLM_BATCH_SIZE` small so the required JSON stays short.

**Why `HINDSIGHT_API_LLM_STRICT_SCHEMA_CONSOLIDATION=true` does not help.** Strict mode asks the provider for its strongest schema mode; a provider that ignores `response_format` has none. `DEFAULT_LLM_STRICT_SCHEMA` is `False`, so the schema is only *requested*, never grammar-enforced.

**Why there is no retry rescue.** `ValidationError` is classified `FAIL_FAST` (`consolidator.py:3621`). Hindsight reasons, correctly, that consolidation pins temperature 0.0 and rebuilds a byte-identical payload, so re-sending asks a greedy decoder the same question and gets the same answer. The caller bisects the batch instead — which cannot help a *systematic* shape error, only an oversized one.

### 20. Consolidation never runs and logs nothing — a stale worker lease
The most confusing failure of the three, because **nothing errors**. Consolidation simply never happens.

Hindsight's background worker claims queued tasks under a lease keyed to its worker id. Recreating or replacing the container — `docker compose up -d` after an `.env` change, `--force-recreate`, an image bump — kills that worker while the lease still points at it. A new worker **will not steal** the task:

```text
global: pending=1 (queried=1/1 schemas: default) | others: 9454be36ad5d:1 | my_active: none
[PENDING_BREAKDOWN] consolidation: total=1 payload_null=0 retry_blocked=0 assigned=0
```

`pending=1`, but `others:` names a worker that no longer exists and the live worker is idle (`my_active: none`). It sits like that indefinitely.

**The trap inside the trap:** POSTing `/consolidate` again returns
```json
{"operation_id":"b6b1eb1c-264b-4001-8833-a477ec63f63a","deduplicated":true}
```
It folds into the **same stuck task**. Retrying looks like it worked and does nothing.

**Recovery** — a restart runs the startup consolidation reconcile, which reclaims tasks whose worker is gone:
```bash
make hindsight-unstick
# then
make hindsight-consolidate
```
Verified: `pending=1 ... others: 9454be36ad5d:1` became `pending=0 ... others: none`.

**How to tell this apart from the other two failures:**

| Symptom | Cause | Fix |
|---|---|---|
| `ValidationError ... input_type=list` | consolidation model returns a bare list | pin a capable model (§19) |
| `OutputTooLongError` | reasoning-heavy model truncated | low-reasoning flash model + small batch (§19) |
| **Nothing at all; `pending>0`, `others:` names a dead worker** | **stale lease after a container recreate** | **`make hindsight-unstick`** |

Because every `.env` change to the `hindsight` service recreates the container, this is easy to hit repeatedly while tuning consolidation settings. Check the queue after any recreate:
```bash
docker compose logs --since 2m hindsight | grep -oE 'global: pending=[0-9]+[^|]*\| others: [^|]*'
```

### 21. The free keyless pool vanishes mid-session (`No active credentials for provider: cloudflare-playground`)
**The single most important operational caveat in this stack.** The keyless pool is **ephemeral**. Observed in one session:

```text
01:24:04  AUTH  Using cloudflare-playground account: ***...     -> status=success
01:35:31  AUTH  No active credentials for provider: cloudflare-playground
```

Eleven minutes apart. The anonymous account OmniRoute was using expired or hit its quota, and `cloudflare-playground` dropped out of the candidate pool entirely:

```text
# before:  candidates: 21 | by provider: {'cloudflare-playground': 20, 'uncloseai': 1}
# after:   candidates: 1  | by provider: {'openrouter': 1}
```

Everything downstream fails at once — Hermes turns, Hindsight retain, and consolidation — all with `401 provider_not_configured`. **Restarting OmniRoute does not recover it** (verified: 12 polls over 3 minutes, still 1 candidate).

Check the pool any time:
```bash
make free-combos
```

OmniRoute's own docs warn about this: *"keyless availability is not guaranteed"* and *"Providers can rate-limit, change models, or go offline."* Treat free keyless capacity as a demo convenience, never as a dependency. If the course must run to a schedule, connect one real provider in the dashboard — the pool then falls back to it automatically instead of going to zero.

### 22. `make hindsight-llm-check` reports `timeout` on every operation
```text
  retain         ok=False timeout (10004 ms)
  consolidation  ok=False timeout (10004 ms)
  reflect        ok=False timeout (10004 ms)
```
Not an auth failure and not a broken stack. The probe has a ~10 s budget; the free keyless provider is browser-driven and routinely takes 30–150 s per call. The same stack returned `connected` at 4672 ms minutes earlier — latency simply fluctuates.

Use the model-independent round trip instead, which is the real proof:
```bash
make hindsight-roundtrip
```

### 23. Memory provider shows `(none — built-in only)` after installing the plugin
`hermes plugins enable` does **not** activate a memory provider. You also need `memory.provider: hindsight` in `config.yaml`:
```bash
make hindsight-enable        # does both
# or manually:
docker exec hermes-agent hermes config set memory.provider hindsight
```
