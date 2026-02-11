# Ticket Transcript Storage Plan

## Architecture Summary

Ticket transcript persistence uses a hybrid model:

1. SwiftData stores transcript run metadata and lifecycle status.
2. Full transcript text is stored in per-run files under Application Support.

This keeps `TicketParty.store` small while preserving durable per-run history and simple metadata queries.

## Storage Layout

Root directory:

- `~/Library/Application Support/TicketParty/transcripts`

Per-run transcript file:

- `transcripts/<project-id>/<ticket-id>/<run-id>.log`

Path rules:

- SwiftData stores `fileRelativePath` (never absolute paths).
- Relative paths are resolved against the TicketParty Application Support root.

File format:

- UTF-8 newline-delimited text.
- `ticket.output` lines are appended as-is.
- `ticket.error` lines are stored with `[ERROR] ` prefix.

## Data Model

### New public model enum and DTO (TicketPartyModels)

- `TicketTranscriptStatus`: `running`, `succeeded`, `failed`, `cancelled`
- `TicketTranscriptRunDTO`

`TicketTranscriptRunDTO` fields:

- `id`
- `projectID`
- `ticketID`
- `requestID`
- `status`
- `startedAt`
- `completedAt`
- `summary`
- `errorMessage`
- `fileRelativePath`
- `lineCount`
- `byteCount`
- `createdAt`
- `updatedAt`

### New SwiftData model (TicketPartyDataStore)

- `TicketTranscriptRun`

Persisted fields:

- `id`
- `projectID`
- `ticketID`
- `requestID`
- `statusRaw`
- `startedAt`
- `completedAt`
- `summary`
- `errorMessage`
- `fileRelativePath`
- `lineCount`
- `byteCount`
- `createdAt`
- `updatedAt`

`TicketTranscriptRun` is included in the shared `ModelContainer` schema.

## Runtime Flow

`CodexViewModel` now coordinates transcript run persistence:

1. `send(ticket:project:)` starts a transcript run before request submission.
2. Streaming `ticket.output` events append to both in-memory UI output and run file.
3. Streaming `ticket.error` events append `[ERROR]` lines and update UI error state.
4. Completion (`ticket.completed`) marks run as `succeeded` or `failed`.
5. Send failures mark the active run failed and close it.

## UI Output Loading

Ticket detail output now follows this read policy:

1. If the ticket has an active run, display live in-memory output.
2. Otherwise, load latest persisted run text from disk via `TicketTranscriptStore`.
3. Apply a read cap (`200_000` bytes) for safety.
4. Show helper text when capped output is shown:
   - `Showing latest output segment.`

## Failure and Recovery Behavior

At `CodexViewModel` startup, `TicketTranscriptStore.markInterruptedRunsAsFailed(now:)` runs once.

- Any stale `running` rows are converted to:
  - `status = failed`
  - `errorMessage = "Interrupted (app/supervisor restart)"`
  - `completedAt = now`

Recovery failures are logged and do not block app startup.

## Retention and Search Notes

Current defaults:

1. Keep all per-run transcript files (no pruning job yet).
2. No full-text transcript search in phase 1.
3. Query/filter by metadata in SwiftData; load transcript text on demand.

Future expansion options:

1. Add retention policy (latest N runs, per-project caps, or age-based pruning).
2. Add summary/index fields for lightweight transcript search.
3. Add optional full-text indexing if product scope requires transcript-wide search.
