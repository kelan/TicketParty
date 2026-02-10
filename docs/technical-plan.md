# TicketParty Technical Plan

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
- Goal: support local-first issue tracking with append-only history and deterministic CLI automation.
- Primary key convention: UUID `id` for every entity.
- Time convention: all timestamps are UTC `Date` values.
- Soft-delete convention: use `archivedAt` and `closedAt`; do not hard-delete in normal workflows.
- Field naming note: task long-form text is conceptually `description`; implementation may store it as `taskDescription` for SwiftData compatibility.
- Workflow and state definitions are code-owned enums, not dynamic records.
- Persist enum values as raw strings in SwiftData for queryability and migration stability.

### Core Tables
| Entity | Purpose | Core Fields | Constraints and Query Hints |
| --- | --- | --- | --- |
| `Task` | Main work item and current-state projection | `id`, `ticketNumber`, `displayID`, `title`, `description`, `priority`, `severity`, `currentWorkflow`, `currentState`, `currentStateChangedAt`, `assigneeID`, `createdAt`, `updatedAt`, `closedAt?`, `archivedAt?` | Unique: `id`, `ticketNumber`, `displayID`; index `currentState`, `assigneeID`, `updatedAt`, `archivedAt` |
| `TaskStateTransition` | Immutable state transition history | `id`, `taskID`, `workflow`, `fromState`, `toState`, `transitionedAt`, `actorType`, `actorID`, `reason?`, `metadataJSON` | Index `taskID + transitionedAt DESC`; index `toState + transitionedAt`; append-only |
| `TaskEvent` | Generic immutable audit/event log | `id`, `taskID`, `eventType`, `actorType`, `actorID`, `timestamp`, `payloadJSON` | Index `taskID + timestamp`; index `eventType + timestamp` |
| `Note` | Long-form durable context | `id`, `taskID`, `body`, `authorType`, `createdAt`, `updatedAt` | Index `taskID + updatedAt` |
| `Comment` | Structured conversation entry | `id`, `taskID`, `authorType`, `authorID`, `type`, `body`, `createdAt`, `inReplyToCommentID?`, `requiresResponse`, `resolvedAt?` | Index `taskID + createdAt`; index `requiresResponse + resolvedAt` |
| `Assignment` | Assignment timeline record | `id`, `taskID`, `assigneeID`, `assignedBy`, `assignedAt`, `unassignedAt?` | Index `taskID + assignedAt`; index `assigneeID + unassignedAt` |
| `Agent` | Known assignee actor | `id`, `name`, `kind`, `isActive` | Unique `id`; optional unique-by-name policy |
| `SessionMarker` | Presence and digest boundaries | `id`, `type`, `timestamp` | Index `type + timestamp` |

### Relationship Rules
- `Task` to `Note`: one-to-many by `Note.taskID`.
- `Task` to `Comment`: one-to-many by `Comment.taskID`.
- `Task` to `TaskEvent`: one-to-many by `TaskEvent.taskID`.
- `Task` to `TaskStateTransition`: one-to-many by `TaskStateTransition.taskID`.
- `Task` to `Assignment`: one-to-many by `Assignment.taskID`.
- `Task` to `Agent`: many-to-one via `Task.assigneeID`.
- `Comment` reply threading: optional self-reference through `inReplyToCommentID`.

### Enum Domains
- `priority`: `low`, `medium`, `high`, `urgent`.
- `severity`: `trivial`, `minor`, `major`, `critical`.
- `workflow` (code-defined): start with `standard`; extend in code only.
- `state` (code-defined for `standard`): `backlog`, `ready`, `in_progress`, `review`, `done`.
- `comment.type`: `update`, `question`, `answer`, `decision`, `status_change`.
- `authorType` and `actorType`: `owner`, `agent`, `system`.
- `agent.kind`: `local_cli`, `api_backed`, `manual`.
- `sessionMarker.type`: `app_active`, `app_inactive`, `digest_viewed`.

### Integrity and Lifecycle Rules
- `Task.updatedAt` must change on every mutation to support optimistic concurrency checks.
- `Task.displayID` follows format `TT-<ticketNumber>` and is immutable after creation.
- `Task.currentState` stores the latest state enum raw value for fast filtering and sorting.
- `Task.currentStateChangedAt` tracks when the current state last changed.
- Closing a task sets `closedAt`; reopening clears `closedAt`.
- Archiving sets `archivedAt`; archived tasks are excluded from default list queries.
- `Comment.requiresResponse == true` implies unresolved until `resolvedAt` is set.
- Every state change appends one `TaskStateTransition` row and one `TaskEvent` row in the same save transaction as the `Task.currentState` update.
- All non-state mutations also append `TaskEvent` rows in the same transaction.

### Current-State Query Strategy
- Current state reads come directly from `Task.currentState` and `Task.currentStateChangedAt` for O(1)-style row access.
- Historical state analysis reads `TaskStateTransition`, not `Task`, to avoid scanning generic events.
- "Latest transition per task" query pattern:
- Filter transitions by `taskID`.
- Sort `transitionedAt DESC`.
- Take first row.

## History Strategy (Forever)
- Append-only `TaskEvent` for all meaningful changes.
- Append-only `TaskStateTransition` for all state changes.
- Never hard-delete task records, transition rows, or event rows in normal operation.
- Use soft-delete/archive for hidden records.
- Build digest and audit views from transitions/events + current task projection.
- Add indexes for `taskID`, `timestamp`, `eventType`, `toState`, `requiresResponse`.

## Workflow Engine
- Validate transitions against code-defined transition map (shared in `TaskCore`).
- Enforce in shared domain layer so UI and CLI behave identically.
- Persist only enum raw values in database (`currentWorkflow`, `currentState`).
- Start with one code-defined workflow (`standard`); add additional presets in code when needed.

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

## CLI Plan
- CLI design details moved to `docs/cli-plan.md`.

## Reliability and Safety
- Use optimistic concurrency marker (`updatedAt`) to detect conflicting writes.
- Emit `TaskEvent` within same transaction as source update.
- Validate required fields and transition rules in one shared service.
- Build minimal backup/export feature early.

## Testing Strategy
- Domain tests for transition validation and comment/question rules.
- Persistence tests for SwiftData queries and event logging.
- CLI integration tests for common agent flows.
- Digest correctness tests with seeded historical timelines.
