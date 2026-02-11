# App-Owned Loop + Supervisor-Executed Task Runtime

## Summary

The loop logic should live in the app.  
The supervisor should run and persist each task it is given, buffer all task events, and replay missed events when the app reconnects.

This gives you:

1. Product/control logic in one place (app).
2. Robust execution and durability at task level (supervisor).
3. No split-brain loop ownership.

## Ownership Split

### App owns

1. Ticket queue ordering and "next ticket" decisions.
2. Cleanup pipeline policy and step ordering.
3. Loop state machine (`start/pause/resume/cancel/fail/complete`) and run snapshot.
4. UI state and user actions.

### Supervisor owns

1. Per-project worker lifecycle.
2. Execution of one submitted task at a time per project.
3. Durable event log for each task.
4. Replay from last ACKed event on reconnect.
5. "Finish current task then idle" behavior if app disconnects.

## Public Interfaces / Types

### App-side core types

1. `LoopRunState` remains app-local and authoritative.
2. `LoopStepExecutionHandle` links app step to supervisor task:
   - `projectID`
   - `runID`
   - `ticketID`
   - `cleanupStep`
   - `taskID`
   - `submittedAt`
3. `SupervisorCursorStore` (persisted by app):
   - `projectID`
   - `lastAckedEventID`

### Supervisor protocol (Unix socket JSON)

Commands:

1. `hello { minProtocolVersion, clientInstanceID }`
2. `submitTask { projectID, taskID, kind, payload, idempotencyKey }`
3. `subscribe { projectID, fromEventID }`
4. `ack { projectID, upToEventID }`
5. `taskStatus { projectID, taskID }`
6. `cancelTask { projectID, taskID }`
7. `listActiveTasks {}`

Events:

1. `task.accepted { projectID, taskID, eventID, timestamp }`
2. `task.output { projectID, taskID, stream, line, eventID, timestamp }`
3. `task.progress { projectID, taskID, phase, eventID, timestamp }`
4. `task.completed { projectID, taskID, result, eventID, timestamp }`
5. `task.failed { projectID, taskID, error, eventID, timestamp }`
6. `worker.stateChanged { projectID, state, eventID, timestamp }`

### Task kinds

1. `codex.ticket`
2. `cleanup.requestRefactor`
3. `cleanup.applyRefactor`
4. `cleanup.commitImplementation`
5. `cleanup.commitRefactor`
6. `cleanup.verifyCleanWorktree`
7. `cleanup.runUnitTests`

## Locked Protocol Defaults

### Event ID and ordering

1. `eventID` is monotonic per project (`Int64`), starting at `1`.
2. Event ordering guarantees apply only within a project stream.
3. App cursor is stored per project as `lastAckedEventID`.

### Task payload schemas

All tasks:

1. `projectID: UUID`
2. `taskID: UUID`
3. `kind: String`
4. `idempotencyKey: String`
5. `payload: Object`

`codex.ticket` payload:

1. `runID: UUID`
2. `ticketID: UUID`
3. `ticketTitle: String`
4. `ticketDescription: String`
5. `workingDirectory: String`
6. `threadID: UUID` (same as `ticketID` by default)

`cleanup.requestRefactor` payload:

1. `runID: UUID`
2. `ticketID: UUID`
3. `ticketTitle: String`
4. `ticketDescription: String`
5. `workingDirectory: String`
6. `sourceTaskID: UUID` (the successful `codex.ticket` task)

`cleanup.applyRefactor` payload:

1. `runID: UUID`
2. `ticketID: UUID`
3. `ticketTitle: String`
4. `ticketDescription: String`
5. `workingDirectory: String`
6. `refactorRequestTaskID: UUID`

`cleanup.commitImplementation` and `cleanup.commitRefactor` payload:

1. `runID: UUID`
2. `ticketID: UUID`
3. `ticketTitle: String`
4. `ticketDescription: String`
5. `workingDirectory: String`
6. `commitType: "implementation" | "refactor"`
7. `baseMessage: String`
8. `includeAgentTrailer: Bool` (default `true`)

`cleanup.verifyCleanWorktree` payload:

1. `runID: UUID`
2. `ticketID: UUID`
3. `workingDirectory: String`

`cleanup.runUnitTests` payload:

1. `runID: UUID`
2. `ticketID: UUID`
3. `workingDirectory: String`
4. `command: [String]` (default: `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination platform=macOS test -only-testing:TicketPartyTests`)

### Idempotency key format

1. `codex.ticket`: `run:{runID}:ticket:{ticketID}:step:codex`
2. Cleanup step: `run:{runID}:ticket:{ticketID}:step:{cleanupStep}`
3. Retry of the same logical step must reuse the same key.

### ACK behavior

1. ACK is batched with `upToEventID` high-watermark.
2. App flushes ACK every 250 ms or every 50 events, whichever comes first.
3. App must flush final ACK immediately after terminal task event processing.

### Cancellation semantics

1. `cancelTask` is cooperative first: supervisor requests graceful stop.
2. Grace timeout: 10 seconds.
3. After timeout, supervisor force terminates worker-side execution and emits `task.failed` with `error.code = "cancelled.force_terminated"`.
4. App treats both graceful and forced cancellation as terminal cancelled outcomes.

### Replay gap behavior

1. If `fromEventID` is older than retained history, supervisor responds with:
   - `replay.truncated { projectID, earliestAvailableEventID, latestEventID }`.
2. App then requests `taskStatus` for active/incomplete tasks and rebuilds local state from:
   - remaining replayable events, and
   - task terminal summaries from `taskStatus`.
3. App stores new cursor at `earliestAvailableEventID - 1` before continuing replay.

### Protocol versioning defaults

1. `protocolVersion = 1` for current implementation.
2. App minimum supported version: `1`.
3. On mismatch:
   - supervisor returns `error { code: "protocol.unsupported", serverVersion }`,
   - app marks supervisor unhealthy and does not run loop actions until versions match.

## Execution Flow

1. App loop picks top ticket.
2. App submits `codex.ticket` task with deterministic `taskID`.
3. Supervisor executes, emits events, persists all events.
4. App consumes events, advances `LoopRunState` only on `task.completed`.
5. App submits cleanup tasks one step at a time.
6. If app disconnects, supervisor finishes current task and goes idle.
7. On reconnect, app calls `subscribe(fromEventID = lastAckedEventID + 1)`.
8. App replays missed events, updates state, sends `ack` as it processes.
9. App decides whether to continue next step/ticket.

## Persistence

### Supervisor persistence

1. Task records per project.
2. Event log with monotonic `eventID`.
3. Active task metadata.
4. Retention policy: 7 days or 10 MB per project.

### App persistence

1. Loop snapshot (run-level state).
2. Last ACKed event cursor per project.
3. Mapping of step execution to `taskID`.

## Failure / Recovery Rules

1. Supervisor restart: app reconnects, re-subscribes from cursor, rebuilds in-memory state.
2. Duplicate `submitTask` (retries): dedupe by `idempotencyKey`.
3. App crash mid-step: on restart, app resumes from snapshot + replayed events.
4. Task fails: app marks loop failed with step context; does not auto-advance.
5. Protocol mismatch: app refuses to run loop and shows actionable upgrade error.

## Test Scenarios

1. App disconnects during `codex.ticket`; supervisor completes task; app reconnects and replays to terminal event.
2. App disconnects during cleanup step; same finish-then-idle behavior.
3. Reconnect with partial ACK; replay starts at `lastAck + 1` exactly once.
4. Duplicate `submitTask` after timeout; supervisor returns existing task status, no double execution.
5. Supervisor restart mid-run; app recovers from persisted cursor and snapshot.
6. Retention pruning does not delete unACKed active-task events.
7. Commit cleanup tasks include ticket title + ticket description/summary in commit payload and resulting commit message.

## Implementation Sequence

1. Extend supervisor protocol with `submitTask/subscribe/ack/taskStatus`.
2. Add durable per-project event log + monotonic event IDs in supervisor.
3. Add app `SupervisorTaskClient` with reconnect + ACK cursor.
4. Add `TicketLoopManager` in app to submit one task per phase and wait for terminal events.
5. Wire cleanup steps through supervisor task kinds.
6. Add replay/recovery integration tests.
7. Add observability on Agents page: active task, last event ID, replay lag.

## Assumptions and Defaults

1. Loop ownership remains in app by design.
2. Supervisor executes exactly one task at a time per project.
3. On app disconnect, supervisor finishes current task and does not start another.
4. Replay model is event sequence with ACK cursor.
5. ACK model is high-watermark batching (`upToEventID`).
6. Event IDs are monotonic per project, not global.
7. Retention default is 7 days or 10 MB per project.
8. Transport stays Unix socket JSON for now; XPC is a later hardening step.
