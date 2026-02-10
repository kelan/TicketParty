# TaskTracker CLI Plan

## Goals
- Provide an agent-first CLI (`tp`) for deterministic automation.
- Share the exact same persistence and domain validation as the app.
- Optimize for scriptable output and stable behavior over interactive UX.

## Runtime and Packaging
- Binary name: `tp`.
- Build target: Swift Package executable target or Xcode command-line target.
- Argument parsing: `swift-argument-parser`.

## Persistence and Store Access
- CLI and app use one shared persistence bootstrap in `TaskPersistence`.
- Shared store path: `~/Library/Application Support/TicketParty/TicketParty.store`.
- Default operation is local-first with CloudKit off.
- Sync-enabled mode may be added later behind explicit configuration.

## Command Execution Pattern
- Create/open shared `ModelContainer`.
- Create `ModelContext` for each command execution.
- Perform fetch/insert/update/delete operations.
- Call `save()` for all write commands.
- Route all write logic through shared domain services to ensure parity with app rules.

## Command Surface (MVP)
- `tp task create --title --workflow --state --priority`
- `tp task list --state --assignee --needs-response --json`
- `tp task show TT-42 --json`
- `tp task assign TT-42 --agent coder-1`
- `tp task transition TT-42 --to in_review`
- `tp note add TT-42 --body`
- `tp comment add TT-42 --type update --body`
- `tp question ask TT-42 --body`
- `tp question answer TT-42 --comment-id C-99 --body`
- `tp digest since --last-active --json`

## Output Contracts
- Default mode: human-readable concise tables.
- `--json` mode: stable keys, deterministic ordering, machine-safe output.
- IDs in output should always include both internal UUID and display ID where relevant.

## Compatibility with `bd`
- Full command parity is not required in MVP.
- Low-cost aliases:
- `tp new` -> `tp task create`
- `tp list` -> `tp task list`
- `tp show` -> `tp task show`
- Prioritize high-quality JSON output over exact CLI parity.

## Reliability and Safety
- Use optimistic concurrency via `updatedAt`.
- For writes, emit `TaskEvent` in the same transaction as source record mutation.
- For state changes, emit `TaskStateTransition` plus `TaskEvent` in the same transaction as `Task.currentState` update.
- Validate required fields and transition rules in one shared service.
- Early backup/export command:
- `tp export --format jsonl`.

## Testing Strategy
- CLI integration tests for create/list/show/assign/transition/comment/question flows.
- JSON output contract tests for deterministic key presence and stable sorting.
- Failure-mode tests:
- Invalid transition.
- Missing required arguments.
- Concurrent mutation conflict.
