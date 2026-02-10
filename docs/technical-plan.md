# TaskTracker Technical Plan

## Stack and App Shape
- Platform: macOS app first (SwiftUI).
- Persistence: SwiftData (local container).
- Architecture style: feature-modular MVVM with repository layer around SwiftData.
- Local-first by default, with schema and identifiers designed for future sync.

## Proposed Modules
- `TaskCore`: domain models and validation rules.
- `TaskPersistence`: SwiftData models, migrations, query utilities.
- `TaskApp`: SwiftUI screens and view models.
- `TaskCLI`: executable target (`tp`) that reuses `TaskCore` + `TaskPersistence`.
- `TaskDigest`: summary/query engine for "while you were away."

## SwiftData Domain Model (MVP+)
- `Task`
- `id` (UUID), `ticketNumber` (Int), `displayID` (String like `TT-42`)
- `title`, `description`, `priority`, `severity`
- `workflowID`, `stateID`, `assigneeID`
- `createdAt`, `updatedAt`, `closedAt?`, `archivedAt?`
- `Note`
- `id`, `taskID`, `body`, `authorType` (owner/agent/system), `createdAt`, `updatedAt`
- `Comment`
- `id`, `taskID`, `authorType`, `authorID`, `type`
- `body`, `createdAt`
- `inReplyToCommentID?`
- `requiresResponse` (Bool), `resolvedAt?`
- `Workflow`
- `id`, `name`, `isDefault`, `createdAt`, `updatedAt`
- `WorkflowState`
- `id`, `workflowID`, `key`, `displayName`, `orderIndex`, `isTerminal`
- `WorkflowTransition`
- `id`, `workflowID`, `fromStateID`, `toStateID`, `label`, `guardExpression?`
- `Assignment`
- `id`, `taskID`, `assigneeID`, `assignedBy`, `assignedAt`, `unassignedAt?`
- `Agent`
- `id`, `name`, `kind` (local CLI, API-backed, manual), `isActive`
- `TaskEvent` (immutable history log)
- `id`, `taskID`, `eventType`, `actorType`, `actorID`, `timestamp`
- `payloadJSON` (field diffs, transition data, metadata)
- `SessionMarker`
- `id`, `type` (`appActive`, `appInactive`, `digestViewed`), `timestamp`

## History Strategy (Forever)
- Append-only `TaskEvent` for all meaningful changes.
- Never hard-delete task records or event rows in normal operation.
- Use soft-delete/archive for hidden records.
- Build digest and audit views from event stream + current projections.
- Add indexes for `taskID`, `timestamp`, `eventType`, `requiresResponse`.

## Workflow Engine
- Validate transitions against `WorkflowTransition` records.
- Enforce in shared domain layer so UI and CLI behave identically.
- Allow per-task workflow binding at creation.
- Keep system workflow available as fallback to avoid broken tasks when custom workflows change.

## Structured Comments Design
- Keep structure lightweight:
- `type` enum: `update`, `question`, `answer`, `decision`, `status_change`.
- `inReplyToCommentID` for directed answers.
- `requiresResponse` flag for question comments.
- Optional metadata dictionary in `payloadJSON` for future fields.
- App surfaces "Open Questions" as first-class queue.

## "While Away" Digest Engine
- Compute window from latest `SessionMarker(type: appInactive)` or last digest view.
- Summarize:
- Completed and newly created tasks.
- State changes by workflow/state.
- Questions awaiting owner response.
- Agent activity volume by assignee.
- Expose digest as shared service used by app and CLI.

## CLI Design
- Binary name: `tp`.
- Build via Swift Package executable target or Xcode command line target.
- Parse commands using `swift-argument-parser`.
- Read/write same SwiftData store location as app.
- Define one shared persistence bootstrap in `TaskPersistence` used by both app and CLI.
- Use an explicit store path so both targets are guaranteed to hit the same file:
- `~/Library/Application Support/TicketParty/TicketParty.store`.
- Keep CloudKit disabled for CLI/local-first mode unless sync mode is explicitly enabled.
- Subcommand execution pattern:
- Create/open shared `ModelContainer`.
- Create `ModelContext` for the command.
- Run fetch/insert/update/delete operations.
- Call `save()` for all write paths.
- Key commands:
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

## Compatibility with `bd`
- Do not require full command compatibility initially.
- Add aliases for common flows where low-cost:
- `tp new` -> `tp task create`
- `tp list` -> `tp task list`
- `tp show` -> `tp task show`
- Prioritize good JSON output over exact command parity.

## Reliability and Safety
- Use optimistic concurrency marker (`updatedAt`) to detect conflicting writes.
- Emit `TaskEvent` within same transaction as source update.
- Validate required fields and transition rules in one shared service.
- Build minimal backup/export feature early:
- `tp export --format jsonl`.

## Testing Strategy
- Domain tests for transition validation and comment/question rules.
- Persistence tests for SwiftData queries and event logging.
- CLI integration tests for common agent flows.
- Digest correctness tests with seeded historical timelines.
