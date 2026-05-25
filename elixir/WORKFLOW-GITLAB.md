---
tracker:
  kind: gitlab
  endpoint: "https://git.tydic.com:11011"
  api_key: $GITLAB_TOKEN
  project_slug: "TRDC-CSR/cloud/vehicle_detection/thirdparty/strong-sort-test"
  active_states:
    - Todo
    - In Progress
    - In Review
    - Rework
    - Merging
  terminal_states:
    - Done
    - Closed
    - Cancelled

polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/humphery755-dev/symphony.git .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: $PRG_HOME/run.sh debug
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
  read_timeout_ms: 60000
---

You are working on a GitLab issue `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the issue is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: GitLab API access, `glab` CLI, or `gitlab_api` tool is available

The agent must be able to interact with GitLab. Symphony must inject a `gitlab_api` dynamic tool (analogous to the `linear_graphql` tool for Linear tracker configurations) that provides API access reusing the configured GitLab credentials from WORKFLOW.md. If `gitlab_api` is not injected by Symphony, the agent must fall back to the `glab` CLI or direct GitLab REST API calls using the configured endpoint and `$GITLAB_TOKEN`. If none of these are available, stop and ask the user to configure GitLab access.

Symphony requirement: When `tracker.kind` is `gitlab`, `dynamic_tool.ex` must inject a `gitlab_api` tool instead of (or in addition to) `linear_graphql`. The `gitlab_api` tool must accept a `method` (GET/POST/PUT/DELETE), `path` (API path relative to `/api/v4/`), and optional `body` (JSON object), executing the request against the configured GitLab endpoint with the configured API key.

## Default posture

- Start by determining the issue's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep issue metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent GitLab note as the source of truth for progress.
- Use that single workpad note for all progress and handoff notes; do not post separate "done"/summary notes.
- Treat any issue-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate GitLab issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be labeled
  `Backlog`, be created in the same project as the current issue, reference the
  current issue via GitLab's related issues, and use GitLab's blocking
  relationship when the follow-up depends on the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `gitlab`: interact with GitLab (issues, merge requests, notes, labels, pipelines).
  Requires: `.codex/skills/gitlab/SKILL.md` — GitLab equivalent of the Linear skill.
  If this skill does not exist, the Symphony system must provide it with equivalent
  functionality: issue/mr/note CRUD, label management, pipeline status, file upload.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish MR updates.
  Requires: `.codex/skills/push/SKILL.md` must support GitLab MRs (create and update
  merge requests via `glab mr create` / `glab mr update`) in addition to or instead
  of GitHub PRs. If the skill is GitHub-only, the Symphony system must provide a
  GitLab-aware push skill.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when issue reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which must support GitLab MR merge (monitor pipelines, resolve conflicts, squash-merge via `glab mr merge`). If the skill is GitHub-only, the Symphony system must provide a GitLab-aware land skill.

## Status map

GitLab issues use labels as workflow states. The configured state labels are:

Active states (label-based): `Todo`, `In Progress`, `In Review`, `Rework`, `Merging`
Terminal states (label-based): `Done`, `Closed`, `Cancelled`

- `Backlog` -> issues with only `Backlog` label (no active state label); out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if an MR is already attached, treat as feedback/rework loop (run full MR feedback sweep, address or explicitly push back, revalidate, return to `In Review`).
- `In Progress` -> implementation actively underway.
- `In Review` -> MR is attached and validated; waiting on human review/approval.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `glab mr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.
- `Closed` -> terminal state; no further action required.
- `Cancelled` -> terminal state; no further action required.

## Step 0: Determine current issue state and route

1. Fetch the issue by explicit issue ID (IID).
2. Read the current state (derived from labels matching configured active/terminal states).
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to add an active state label (e.g., `Todo`).
   - `Todo` -> immediately move to `In Progress` (apply `In Progress` label, remove `Todo` label), then ensure bootstrap workpad note exists (create if missing), then start execution flow.
     - If MR is already attached, start by reviewing all open MR comments/discussions and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current workpad note.
   - `In Review` -> wait and poll for decision/review updates.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `glab mr merge` directly.
   - `Rework` -> run rework flow.
   - `Done`/`Closed`/`Cancelled` -> terminal state; do nothing and shut down.
4. Check whether an MR already exists linked to this issue or for the current branch, and whether it is closed/merged.
   - If a branch MR exists and is `closed` or `merged`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
   - GitLab-specific: since the GitLab adapter does not provide `branch_name`, search for open MRs by source branch via `glab mr list --source-branch=$(git branch --show-current)` or GitLab API.
5. For `Todo` issues, do startup sequencing in this exact order:
   - `update_issue_state(..., "In Progress")` (apply `In Progress` label, remove `Todo` label)
   - find/create `## Codex Workpad` bootstrap note
   - only then begin analysis/planning/implementation work.
6. Add a short note if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent workpad note for the issue:
    - Search existing notes for a marker header: `## Codex Workpad`.
    - Ignore resolved notes/discussions while searching; only active/unresolved notes are eligible to be reused as the live workpad.
    - If found, reuse that note; do not create a new workpad note.
    - If not found, create one workpad note and use it for all updates.
    - Persist the workpad note ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad note.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/42@7bdde33bc`
    - Do not include metadata already inferable from GitLab issue fields (`issue IID`, `status`, `branch`, `MR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same note.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the issue description/note context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the note.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## MR feedback sweep protocol (required)

When an issue has an attached MR, run this protocol before moving to `In Review`:

1. Identify the MR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level MR notes/discussions (`glab mr view <id> --comments` or `glab api /projects/:id/merge_requests/:iid/notes`).
   - Inline code review discussions (`glab api /projects/:id/merge_requests/:iid/discussions` — filter for `type: "DiffNote"`).
   - MR approvals status (`glab mr approvals <id>` or `glab api /projects/:id/merge_requests/:iid/approvals`).
3. Treat every actionable reviewer comment (human or bot), including inline review discussions, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that discussion thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitLab API access is **not** a valid blocker by default — the WORKFLOW.md config provides credentials. Always try fallback strategies first (alternate auth mode, `glab` CLI, direct API calls), then continue publish/review flow.
- Do not move to `In Review` for GitLab access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitLab required tool is missing, or required non-GitLab auth is unavailable, move the issue to `In Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level notes outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> In Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad note and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
    - GitLab note editing: use `glab api -X PUT /projects/:id/issues/:iid/notes/:note_id -f body='<updated content>'` or the `gitlab_api` tool if available.
4.  Implement against the hierarchical TODOs and keep the note current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For issues that started as `Todo` with an attached MR, run the full MR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all issue-provided `Validation`/`Test Plan`/`Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach MR URL to the issue (prefer GitLab's native MR-issue linking; use the workpad note only if linking is unavailable).
    - Ensure the GitLab MR has label `symphony` (add it if missing via `glab mr update <id> --label symphony`).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad note with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad note.
    - Do not include MR URL in the workpad note; keep MR linkage on the issue via GitLab's native MR-issue linking.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary note.
11. Before moving to `In Review`, poll MR feedback and pipeline status:
    - Read the MR `Manual QA Plan` note (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full MR feedback sweep protocol.
    - Confirm MR pipeline is passing (green) after the latest changes via `glab ci status --branch <branch>` or GitLab API `GET /projects/:id/pipelines?ref=<branch>`.
    - Confirm every required issue-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and pipeline is fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `In Review` (apply `In Review` label, remove `In Progress` label).
    - Exception: if blocked by missing required non-GitLab tools/auth per the blocked-access escape hatch, move to `In Review` with the blocker brief and explicit unblock actions.
13. For `Todo` issues that already had an MR attached at kickoff:
    - Ensure all existing MR feedback was reviewed and resolved, including inline review discussions (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `In Review`.

## Step 3: In Review and merge handling

1. When the issue is in `In Review`, do not code or change issue content.
2. Poll for updates as needed, including GitLab MR review discussions from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` (apply `Rework` label, remove `In Review` label) and follow the rework flow.
4. If approved, human moves the issue to `Merging` (applies `Merging` label, removes `In Review` label).
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the MR is merged. Do not call `glab mr merge` directly.
6. After merge is complete, move the issue to `Done` (apply `Done` label, remove `Merging` label).

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human notes; explicitly identify what will be done differently this attempt.
3. Close the existing MR tied to the issue via `glab mr close <id>`.
4. Remove the existing `## Codex Workpad` note from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` note.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before In Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad note.
- Acceptance criteria and required issue-provided validation items are complete.
- Validation/tests are green for the latest commit.
- MR feedback sweep is complete and no actionable comments remain.
- MR pipeline is green, branch is pushed, and MR is linked on the issue.
- Required MR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from validation steps are complete.

## Guardrails

- If the branch MR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch MRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to apply an active state label.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad note (`## Codex Workpad`) per issue.
- If note editing is unavailable in-session, use the GitLab API (`glab api -X PUT /projects/:id/issues/:iid/notes/:note_id`). Only report blocked if both direct API editing and CLI-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate `Backlog`-labeled issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project creation, a related
  issue link to the current issue, and a blocking relationship when the
  follow-up depends on the current issue.
- Do not move to `In Review` unless the `Completion bar before In Review` is satisfied.
- In `In Review`, do not make changes; wait and poll.
- If state is terminal (`Done`/`Closed`/`Cancelled`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker note describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad note and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
