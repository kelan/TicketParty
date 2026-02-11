# Ticket Processing Loop Playbook

## Goal

Run tickets in strict project order with reliable task completion semantics:

1. App picks the top eligible ticket.
2. App submits a single task (`codex.ticket`) to the agent runtime.
3. Agent runtime owns execution until terminal (`task.completed` or `task.failed`).
4. If ticket succeeds, app submits cleanup tasks one-by-one.
5. If all cleanup succeeds, app advances to next ticket.
6. On failure/cancel/pause, app stops advancing and preserves resumable state.

## Core Ownership Model

### App owns loop driving logic

1. Queue ordering and next-ticket selection.
2. Loop state machine and snapshot persistence.
3. Cleanup policy, step ordering, and advancement rules.
4. Pause/resume/cancel user actions.
5. UI state and observability.

### Agent runtime (supervisor + sidecar/task executor) owns task completion

1. Once `submitTask` is accepted, runtime drives that task to terminal.
2. Per-project worker lifecycle and single in-flight task per project.
3. Event streaming + durable per-project event log.
4. Replay from app cursor on reconnect.
5. If app disconnects, runtime still finishes current task, then idles.

This avoids split-brain ownership: app decides *what* runs next; runtime guarantees *submitted task* completion.

## State Model (App)

```swift
enum LoopRunState: Sendable, Equatable {
    case idle
    case preparingQueue
    case running(RunProgress)
    case paused(PauseReason, RunProgress)
    case failed(FailureContext, RunProgress)
    case completed(RunSummary)
    case cancelling(RunProgress)
}

struct RunProgress: Sendable, Equatable {
    let projectID: UUID
    let runID: UUID
    let total: Int
    let index: Int
    let currentTicketID: UUID?
    let ticketPhase: TicketPhase?
}

enum TicketPhase: Sendable, Equatable {
    case sendingToCodex
    case awaitingCodexResult
    case runningCleanup(step: CleanupStep, stepIndex: Int, totalSteps: Int)
    case markingDone
}
```

## Persistence

### App persistence

1. `LoopRunSnapshot` per project (JSON now; SwiftData later).
2. Supervisor event cursor per project (`lastAckedEventID`).
3. Step/task linkage (`runID`, `ticketID`, `cleanupStep`, `taskID`).

### Runtime persistence

1. Task records per project.
2. Event log (`eventID` monotonic per project).
3. Project log metadata (`nextEventID`, `lastAckedEventID`).
4. Retention defaults: 7 days or 10 MB per project.

## Protocol Contract (Unix socket JSON)

### Commands

1. `hello`
2. `submitTask { projectID, taskID, kind, ticketID, workingDirectory, prompt, payload, idempotencyKey }`
3. `subscribe { projectID, fromEventID }`
4. `ack { projectID, upToEventID }`
5. `taskStatus { projectID?, taskID? }`
6. `cancelTask { projectID, taskID }`
7. `listActiveTasks`

### Events

1. `task.accepted`
2. `task.output`
3. `task.completed`
4. `task.failed`
5. worker events (`worker.started`, `worker.exited`)

### Ordering and replay

1. Event IDs are monotonic per project.
2. App subscribes with `fromEventID = lastAckedEventID + 1`.
3. App ACKs processed high-watermark events.
4. On reconnect/restart, app rebuilds state from replay + `taskStatus`.

## Task Kinds and Cleanup Pipeline

### Ticket task

1. `codex.ticket`

### Cleanup tasks (default order)

1. `cleanup.commitImplementation`
2. `cleanup.requestRefactor`
3. `cleanup.applyRefactor`
4. `cleanup.commitRefactor`
5. `cleanup.verifyCleanWorktree`
6. `cleanup.runUnitTests`

### Commit requirements

Commit cleanup steps must include ticket context in payload and resulting commit message:

1. Ticket title.
2. Ticket description (or concise summary).
3. `Agent: Codex` trailer when configured.

## Idempotency and Determinism

1. Every logical step uses a deterministic `idempotencyKey`:
   - `run:{runID}:ticket:{ticketID}:step:codex`
   - `run:{runID}:ticket:{ticketID}:step:{cleanupStep}`
2. Retries reuse same key.
3. Runtime deduplicates duplicate submissions and returns existing `taskID`.

## Execution Flow

1. App starts loop, snapshots queue, sets `preparingQueue`.
2. For current ticket, app submits `codex.ticket`.
3. Runtime executes task to terminal and emits events.
4. App waits for terminal event; if failed, mark loop failed and stop.
5. If successful, app submits cleanup steps serially.
6. On cleanup failure, mark loop failed and stop.
7. On all-success, mark ticket complete, persist snapshot, advance index.
8. When queue exhausted, mark loop completed and clear snapshot.

## Failure, Pause, Cancel, Resume

1. Task failure: loop transitions to `.failed` with step context.
2. Pause: app sets intent and stops before next phase boundary.
3. Cancel: app sends `cancelTask` for active task and transitions through `.cancelling`.
4. App crash/restart: reload snapshot + replay events + continue from last durable point.
5. Runtime restart: app reconnects, re-subscribes, and rebuilds in-memory state.

## Current Implementation Alignment

Implemented in repo:

1. App `TicketLoopManager` owns orchestration and snapshots.
2. `CodexManager` supports generic submit/wait/cancel task flow.
3. Runtime handles task protocol, durable events, and cleanup task execution.
4. Agents page shows supervisor health + loop state and actions.
5. Unit tests cover loop happy path, cleanup failure path, and commit payload context.

## Remaining Hardening (Next)

1. Add explicit `task.progress` phases for richer UI.
2. Add retention/replay truncation signaling (`replay.truncated`) handling end-to-end.
3. Move loop snapshots from JSON to SwiftData model.
4. Add deeper recovery tests for app/runtime restart mid-step.
5. Add stricter timeout and cooperative cancellation policies per task kind.
