# TaskTracker CLI Plan

## Goals
- Provide an agent-first CLI (`tp`) for deterministic automation.
- Eliminate dual-writer race conditions against SwiftData.
- Keep app and CLI behavior consistent by sharing one mutation path.

## Architecture Decision
- Use XPC with a single writer service.
- `tp` does not open the SwiftData store directly.
- The XPC service owns all reads/writes and is the only process touching the store.
- The app UI becomes an XPC client too, instead of writing directly to SwiftData.

## Target Layout
- `TaskCore`: validation, workflows/state transitions, shared domain types.
- `TaskPersistence`: SwiftData models, store bootstrap, repository implementation.
- `TaskStoreXPCService`: XPC Mach service target; owns `ModelContainer` and all persistence operations.
- `TaskStoreClient`: shared XPC client wrapper used by app + CLI.
- `TaskApp`: SwiftUI UI process; calls `TaskStoreClient`.
- `TaskCLI` (`tp`): command-line target; calls `TaskStoreClient`.

## XPC Contract (MVP)
- Request style: async request/response methods (no streaming in v1).
- Response style: Codable DTO payloads, not SwiftData model objects.
- Core methods:
- `createTask(input) -> TaskDTO`
- `listTasks(filter, page) -> TaskListDTO`
- `getTask(idOrDisplayID) -> TaskDTO`
- `updateTask(id, patch) -> TaskDTO`
- `assignTask(id, assignee) -> TaskDTO`
- `transitionTask(id, toState, reason?) -> TaskDTO`
- `addNote(taskID, body) -> NoteDTO`
- `addComment(taskID, type, body, replyTo?) -> CommentDTO`
- `answerQuestion(taskID, commentID, body) -> CommentDTO`
- `getDigest(window) -> DigestDTO`

## Persistence Ownership
- Service opens shared store at `~/Library/Application Support/TicketParty/TicketParty.store`.
- Service keeps one long-lived `ModelContainer`.
- Each XPC request executes in a short-lived operation context:
- Load/validate input.
- Apply domain rules.
- Persist source change.
- Persist `TaskEvent` and `TaskStateTransition` when applicable.
- Save once per request.

## Lifecycle and Availability
- Preferred: launchd-backed Mach service so CLI works even when app is not open.
- App process should not be the persistence server.
- CLI behavior when service unavailable:
- Retry brief connection backoff.
- Emit actionable error with exit code.

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
- Include both UUID and display ID in task-oriented responses.

## Compatibility with `bd`
- Full command parity is not required in MVP.
- Low-cost aliases:
- `tp new` -> `tp task create`
- `tp list` -> `tp task list`
- `tp show` -> `tp task show`
- Prioritize high-quality JSON output over exact CLI parity.

## Reliability and Safety
- Centralize optimistic concurrency checks (`updatedAt`) inside service.
- For writes, emit `TaskEvent` in the same transaction as source mutation.
- For state changes, emit `TaskStateTransition` plus `TaskEvent` in the same transaction as `Task.currentState` update.
- Validate required fields and transition rules in one shared service path.
- Preserve `tp export --format jsonl` as a service-backed command.

## Migration Plan
- Phase 1: Define DTOs and XPC protocol; implement read-only methods.
- Phase 2: Move all write commands to XPC service; keep app direct-write disabled.
- Phase 3: Move app UI reads to XPC for complete parity.
- Phase 4: Remove any remaining direct store access from CLI and app layers.

## Testing Strategy
- XPC contract tests for all request/response methods.
- CLI integration tests against a test service instance.
- App integration tests with service online/offline behavior.
- Failure-mode tests:
- Invalid transition.
- Missing required arguments.
- Concurrent mutation conflict.
- Service unavailable / reconnect behavior.
