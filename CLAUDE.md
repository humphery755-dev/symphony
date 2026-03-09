# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Symphony

Symphony is a long-running orchestration service that polls Linear for issues, creates isolated per-issue workspaces, and runs Codex (OpenAI's coding agent) in app-server mode inside each workspace. The reference implementation lives in `elixir/`. The spec is in `SPEC.md`.

## Development (elixir/)

All commands run from `elixir/`. Use `mise exec --` prefix if Elixir/Erlang aren't on PATH.

```bash
mise install           # install Elixir 1.19 / OTP 28 via mise
mix setup              # install deps (alias for mix deps.get)
mix build              # compile escript → bin/symphony
./bin/symphony ./WORKFLOW.md   # run the service
./bin/symphony --port 4000 ./WORKFLOW.md  # also start Phoenix dashboard
```

**Quality gate (run before handoff):**

```bash
make all               # setup + build + fmt-check + lint + coverage + dialyzer
```

Individual targets:

```bash
mix test               # run tests
mix test --cover       # run tests with coverage (100% threshold enforced)
mix format             # auto-format
mix format --check-formatted  # check formatting (CI)
mix lint               # specs.check + credo --strict
mix dialyzer           # type checking
mix specs.check        # verify all public functions have @spec
mix pr_body.check --file /path/to/pr_body.md  # validate PR body format
```

Run a single test file:

```bash
mix test test/symphony_elixir/orchestrator_test.exs
```

## Architecture

The Elixir OTP application (`SymphonyElixir.Application`) supervises:

- **`Orchestrator`** (`lib/symphony_elixir/orchestrator.ex`) — GenServer that runs the polling loop. Reads `WORKFLOW.md` config via `WorkflowStore`, calls the `Tracker` to fetch Linear issues, dispatches new issues to `AgentRunner`, and reconciles completed/failed runs. Maintains concurrency limits and retry state.

- **`AgentRunner`** (`lib/symphony_elixir/agent_runner.ex`) — Manages the lifecycle of a single issue: creates a workspace (via `Workspace`), builds the Codex prompt (via `PromptBuilder`), launches `Codex.AppServer`, and handles multi-turn retry until the issue reaches terminal state or `max_turns` is hit.

- **`Codex.AppServer`** (`lib/symphony_elixir/codex/`) — Subprocess wrapper for `codex app-server`. Streams JSON events from the Codex process, handles token accounting, and injects the `linear_graphql` dynamic tool so Codex can make raw Linear GraphQL calls during sessions.

- **`Tracker`** / **`Linear.Client`** (`lib/symphony_elixir/tracker/`, `lib/symphony_elixir/linear/`) — Polls Linear GraphQL API. `Tracker` defines the behavior; `Linear.Client` implements it.

- **`Config`** (`lib/symphony_elixir/config.ex`) — Single access point for all runtime config. Prefer adding new config reads here rather than ad-hoc env reads.

- **`Workflow`** / **`WorkflowStore`** (`lib/symphony_elixir/workflow.ex`, `workflow_store.ex`) — Parses `WORKFLOW.md` YAML front matter and Liquid template body. `WorkflowStore` hot-reloads config without stopping agents.

- **`Workspace`** (`lib/symphony_elixir/workspace.ex`) — Creates and manages per-issue workspace directories under the configured root. Runs `hooks.after_create` / `hooks.before_remove` shell hooks.

- **Phoenix web layer** (`lib/symphony_elixir_web/`) — Optional LiveView dashboard at `/` and JSON API at `/api/v1/*`. Enabled via `--port` flag. Uses Bandit as HTTP server.

**Data flow:** `Orchestrator` polls Linear → dispatches issues to `AgentRunner` → `AgentRunner` creates workspace + calls `Codex.AppServer` → Codex receives Liquid-rendered prompt + `linear_graphql` tool → Codex modifies workspace files and calls Linear → `AgentRunner` reports result back to `Orchestrator`.

## Key Conventions

**`@spec` requirement:** All public functions (`def`) in `lib/` must have an adjacent `@spec`. `defp` and `@impl` callbacks are exempt. Validated by `mix specs.check`.

**Logging:** Issue-related logs must include `issue_id` (Linear UUID) and `issue_identifier` (e.g. `MT-620`). Codex lifecycle logs must include `session_id`. See `docs/logging.md` for full conventions.

**PR body:** Must follow `.github/pull_request_template.md` exactly. Validate with `mix pr_body.check`.

**Docs update policy:** If behavior or config changes, update `README.md`, `elixir/README.md`, and `WORKFLOW.md` in the same PR.

**Workspace safety:** Never run Codex with a cwd inside the source repo. Workspaces must stay under the configured `workspace.root`.

**Scope:** Keep changes narrowly scoped. Follow existing module/style patterns in `lib/symphony_elixir/*`. The implementation may extend `SPEC.md` but must not conflict with it.
