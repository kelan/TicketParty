# AGENTS.md

## Planning

- Use 'bd' for task tracking
- Put docs and plans in `docs/` dir

## Commit Attribution

- Codex-authored commits must use `git codex-commit` (local alias for distinct author attribution).
- Ensure local alias exists:
  - `git config --local alias.codex-commit 'commit --author="Codex <kelan+codex@users.noreply.github.com>"'`
- Codex-authored commits must include this trailer in the commit message:
  - `Agent: Codex`
- Example:
  - `git codex-commit -m "Implement X" -m "Agent: Codex"`

## Build/Test Commands

All commands assume macOS with Xcode installed. The project uses an `.xcodeproj` with a single scheme `Cycle`.

- Open in Xcode

```bash
open Cycle.xcodeproj
# or
xed .
```

- Build (Debug)

```bash
xcodebuild -project Cycle.xcodeproj -scheme Cycle -configuration Debug build
```

- Clean build artifacts

```bash
xcodebuild -project Cycle.xcodeproj -scheme Cycle clean
```

- Run all tests (macOS)

```bash
xcodebuild -project Cycle.xcodeproj -scheme Cycle -destination 'platform=macOS' test
```

- Run only unit tests target

```bash
xcodebuild -project Cycle.xcodeproj -scheme Cycle -destination 'platform=macOS' \
  test -only-testing:CycleTests
```

- Run only UI tests target

```bash
xcodebuild -project Cycle.xcodeproj -scheme Cycle -destination 'platform=macOS' \
  test -only-testing:CycleUITests
```

- Run a single test (examples)

```bash
# UI test by class/method
xcodebuild -project Cycle.xcodeproj -scheme Cycle -destination 'platform=macOS' \
  test -only-testing:CycleUITests/CycleUITests/testExample

# Swift Testing (unit) example — adjust identifiers to the struct/method in CycleTests.swift
xcodebuild -project Cycle.xcodeproj -scheme Cycle -destination 'platform=macOS' \
  test -only-testing:CycleTests/CycleTests/example
```

- Notes on linting

SwiftLint and SwiftFormat are configured via `config/` with root symlinks.
Pre-commit hooks are managed by `prek` using `.pre-commit-config.yaml`.

## High-level architecture

Cycle is a SwiftUI macOS app that schedules and executes local “jobs” and records structured run history using SwiftData. The code is organized into three conceptual layers with SwiftData as the persistence backbone.

- App bootstrap (Cycle/CycleApp.swift)
  - Creates a shared SwiftData `ModelContainer` with entities: `Job`, `Trigger`, `Run`, `Event`, `Artifact`, `StateEntry`.
  - Starts long‑running actors:
    - `TriggerScheduler` — evaluates schedules/triggers and enqueues new `Run` rows.
    - `RunExecutor` — executes queued runs with limited concurrency and updates run status/outputs.
  - Declares two primary windows via `Commands`: “Jobs” and “Status”.

- Domain model (Cycle/Models.swift)
  - Entities capture job definitions, triggers, individual runs, emitted events, and artifacts.
  - Key enums: `JobKind` (`shell`, `builtin`), `TriggerType` (`cron`, `interval`, `fsWatch`, `event`, `stateChange`, `manual`), `RunStatus` (queued→running→terminal states), `ArtifactKind`.
  - Relationships: `Job` 1‑to‑many `Trigger` and `Run`; `Run` 1‑to‑many `Artifact`; `Event` links to a `Run`.

- Scheduling (Cycle/TriggerScheduler.swift, docs/scheduling-and-triggers.md)
  - An `actor` loop periodically scans enabled `Trigger` rows and decides whether to enqueue a run.
  - Supports interval and cron triggers, with optional `debounceMs`/`throttleMs` gating.
  - Cron parsing/next‑fire computation is provided by `CronSchedule`.

- Cron computation (Cycle/CronSchedule.swift)
  - Parses standard 5‑field cron expressions with ranges, steps, lists, and Sunday as 0/7.
  - Implements “either DOM or DOW may match” logic when neither field is wildcard, mirroring common cron behavior.

- Execution (Cycle/RunExecutor.swift, docs/execution-and-logging.md)
  - Polls `Run` rows with status `queued`, marks them `running`, and executes according to `Job.kind`.
  - `shell` jobs run via `/bin/zsh -lc <command>` with optional working dir and timeout; stdout/stderr are streamed to temp files and persisted as paths on the `Run`.
  - Concurrency is bounded (`maxConcurrentRuns`). Terminal states set: `success`, `failed`, or `timeout` with exit code and error message.
  - `builtin` jobs are currently stubbed (set to failed with a message).

- UI (SwiftUI)
  - Window “Jobs” renders the main editor/list (`ContentView`).
  - Window “Status” renders historical status/logs (`StatusHistoryView`). Views bind to SwiftData for live updates.

## Working notes for agents

- Persistence & threading
  - All persistence is via SwiftData. Actors (`TriggerScheduler`, `RunExecutor`) create short‑lived `ModelContext`s per loop/operation. Save after mutating models, especially when transitioning run states.

- Adding new triggers or job kinds
  - Extend `TriggerType`/`JobKind` in Models and update `TriggerScheduler`/`RunExecutor` switch statements accordingly.
  - For new schedule types, mirror the pattern used for `interval` and `cron` (JSON config decoding helpers already exist).

- Logs and artifacts
  - `RunExecutor` persists stdout/stderr file paths on `Run`; `Artifact`/`Event` tables exist for richer logs and can be used to implement streaming event logs as described in `docs/execution-and-logging.md`.

## Reference docs in this repo

- docs/architecture-overview.md — big‑picture modules and goals
- docs/job-models.md — conceptual schemas for `Job`, `Run`, `Trigger`, and events
- docs/execution-and-logging.md — execution pipeline and event model
- docs/scheduling-and-triggers.md — scheduler, trigger semantics, and policies

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
