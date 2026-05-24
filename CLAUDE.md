# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Symphony

Symphony is a long-running orchestration service that polls Linear for issues, creates isolated per-issue workspaces, and runs Codex (OpenAI's coding agent) in app-server mode inside each workspace. The reference implementation lives in `elixir/`. The spec is in `SPEC.md`.

## Development (elixir/)

All commands run from `elixir/` with `mise exec --` prefix (required — project needs Elixir 1.19 / OTP 28, see `mise.toml`).

```bash
mise install           # install Elixir 1.19 / OTP 28 via mise
mise exec -- mix setup              # install deps (alias for mix deps.get)
mise exec -- mix build              # compile escript → bin/symphony
mise exec -- ./bin/symphony ./WORKFLOW.md   # run the service
mise exec -- ./bin/symphony --port 4000 ./WORKFLOW.md  # also start Phoenix dashboard
```

**Quality gate (run before handoff):**

```bash
mise exec -- make all               # setup + build + fmt-check + lint + coverage + dialyzer
```

Individual targets:

```bash
mise exec -- mix test               # run tests
mise exec -- mix test --cover       # run tests with coverage (100% threshold enforced)
mise exec -- mix test test/symphony_elixir/orchestrator_test.exs  # single test file
mise exec -- mix format             # auto-format
mise exec -- mix format --check-formatted  # check formatting (CI)
mise exec -- mix lint               # specs.check + credo --strict
mise exec -- mix dialyzer           # type checking
mise exec -- mix specs.check        # verify all public functions have @spec
mise exec -- mix pr_body.check --file /path/to/pr_body.md  # validate PR body format
mise exec -- make e2e               # live end-to-end test (SYMPHONY_RUN_LIVE_E2E=1)
```

**Snapshot testing:** Set `UPDATE_SNAPSHOTS=1` to regenerate dashboard snapshot fixtures.

**Test support:** `SymphonyElixir.TestSupport` (`test/support/test_support.exs`) provides a `use` macro that sets up a temp WORKFLOW.md, common aliases, and cleanup. Most tests use it.

## Architecture

### Supervision Tree

The OTP application (`SymphonyElixir.Application`, defined in `lib/symphony_elixir.ex`) starts children under a `:one_for_one` supervisor in this order:

1. **Phoenix.PubSub** (named `SymphonyElixir.PubSub`) — broadcast for LiveView dashboard
2. **Task.Supervisor** (named `SymphonyElixir.TaskSupervisor`) — dynamic supervisor for agent tasks
3. **WorkflowStore** — GenServer that caches and hot-reloads `WORKFLOW.md`
4. **Orchestrator** — GenServer running the main polling and dispatch loop
5. **HttpServer** — conditionally starts Phoenix Endpoint (returns `:ignore` if no `--port`)
6. **StatusDashboard** — GenServer rendering a terminal ANSI dashboard (disabled in `:test` env)

### Config Flow

Runtime config is loaded from `WORKFLOW.md` YAML front matter, **not** from Mix config files:

```
WORKFLOW.md → Workflow.load/1 (parses YAML + prompt body)
            → WorkflowStore (caches, polls every 1s, keeps last-good on error)
            → Config.settings!/0 (validates via Ecto embedded schema)
            → Config.Schema (typed accessors for all config sections)
```

- `$ENV_VAR` syntax in any string field resolves from the environment at load time.
- `WorkflowStore` re-reads `WORKFLOW.md` every second. If parsing fails, it keeps the last valid config.
- `elixir/config/config.exs` only sets Phoenix defaults (JSON lib, endpoint); all business config comes from the workflow file.
- Ecto is used for **embedded schema validation only** — there is no database.

### Core Modules

- **`Orchestrator`** (`lib/symphony_elixir/orchestrator.ex`) — GenServer state machine. Polls Linear via `Tracker`, dispatches issues to `AgentRunner` via `Task.Supervisor`, reconciles completed/failed/blocked runs, manages retry backoff. State tracks `running`, `claimed`, `blocked`, `completed`, and `retry_attempts` maps.

- **`AgentRunner`** (`lib/symphony_elixir/agent_runner.ex`) — Stateless module. Runs a single issue lifecycle: creates a workspace (via `Workspace`), builds the Codex prompt (via `PromptBuilder` using Liquid templates), launches `Codex.AppServer`, streams events back to the Orchestrator, and handles multi-turn retry up to `max_turns`.

- **`Codex.AppServer`** (`lib/symphony_elixir/codex/app_server.ex`) — JSON-RPC 2.0 client for the `codex app-server` process over stdio. Opens a Port (local bash or remote SSH), then: `initialize` → `thread/start` → `turn/start` → event receive loop. Injects the `linear_graphql` dynamic tool. Handles approval, elicitation, and tool-call messages.

- **`Tracker`** / **`Linear.Client`** (`lib/symphony_elixir/tracker.ex`, `linear/`) — `Tracker` defines the behaviour; `Linear.Client` implements it against Linear's GraphQL API. A `Memory` adapter exists for testing (`tracker/memory.ex`).

- **`Config`** / **`Config.Schema`** (`lib/symphony_elixir/config.ex`, `config/schema.ex`) — Single access point for all runtime config. Schema is an Ecto embedded schema with sub-schemas for each config section (`Tracker`, `Polling`, `Workspace`, `Agent`, `Codex`, `Hooks`, `Observability`, `Server`). Prefer adding new config reads here.

- **`Workflow`** / **`WorkflowStore`** (`lib/symphony_elixir/workflow.ex`, `workflow_store.ex`) — Parses `WORKFLOW.md` YAML front matter and Liquid template body. `WorkflowStore` hot-reloads config without restarting agents.

- **`Workspace`** (`lib/symphony_elixir/workspace.ex`) — Creates isolated per-issue workspace directories. Supports local and SSH-remote workspaces. Runs lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`). Uses `PathSafety` to canonicalize paths and detect symlink escapes.

- **`SSH`** (`lib/symphony_elixir/ssh.ex`) — Thin wrapper for remote workspace execution. Opens persistent SSH Ports for Codex app-server streaming or runs one-shot commands. SSH hosts are configured via `worker.ssh_hosts` in `WORKFLOW.md`.

- **Phoenix web layer** (`lib/symphony_elixir_web/`) — Optional, enabled via `--port` flag. LiveView dashboard at `/`, JSON API at `/api/v1/state` (full snapshot), `/api/v1/:issue_identifier` (single issue), and `/api/v1/refresh` (POST, triggers a poll cycle). Real-time updates via PubSub on `"observability:dashboard"` topic.

### Key Dependencies

| Dep | Purpose |
|---|---|
| `solid` | Liquid template engine for prompt rendering |
| `yaml_elixir` | YAML front matter parsing |
| `ecto` | Embedded schema validation (no database) |
| `req` | HTTP client for Linear GraphQL API |
| `phoenix` / `phoenix_live_view` | Optional web dashboard |
| `bandit` | Phoenix HTTP server |
| `credo` | Elixir linter |
| `dialyxir` | Type checking |

### Data Flow

`Orchestrator` polls Linear → dispatches issues to `AgentRunner` via `Task.Supervisor` → `AgentRunner` creates workspace + calls `Codex.AppServer` → Codex receives Liquid-rendered prompt + `linear_graphql` tool → Codex modifies workspace files and calls Linear → `AgentRunner` reports result back to `Orchestrator`.

## Key Conventions

**`@spec` requirement:** All public functions (`def`) in `lib/` must have an adjacent `@spec`. `defp` and `@impl` callbacks are exempt. Validated by `mix specs.check`.

**Logging:** Issue-related logs must include `issue_id` (Linear UUID) and `issue_identifier` (e.g. `MT-620`). Codex lifecycle logs must include `session_id`. See `docs/logging.md` for full conventions.

**PR body:** Must follow `.github/pull_request_template.md` exactly. Validate with `mix pr_body.check`.

**Docs update policy:** If behavior or config changes, update `README.md`, `elixir/README.md`, and `WORKFLOW.md` in the same PR.

**Workspace safety:** Never run Codex with a cwd inside the source repo. Workspaces must stay under the configured `workspace.root`. `PathSafety` canonicalizes paths and detects symlink escapes.

**Scope:** Keep changes narrowly scoped. Follow existing module/style patterns in `lib/symphony_elixir/*`. The implementation may extend `SPEC.md` but must not conflict with it.
