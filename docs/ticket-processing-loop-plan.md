# Ticket Processing Loop Plan

## Goal

Process tickets in strict sequence for a project:

1. Pick top ticket.
2. Send to Codex and wait for terminal result.
3. If successful, run cleanup pipeline.
4. If cleanup succeeds, advance to next ticket.
5. Stop on failure/cancel/pause with resumable state.

## Why a New Manager

The current manager at `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift` supports one-off sends and output streaming, but not:

- queue/run state,
- ticket terminal completion tracking,
- post-ticket cleanup orchestration,
- resumable loop progress.

## State Model

Use explicit state enums instead of independent booleans.

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

enum CleanupStep: String, Sendable, CaseIterable {
    case commitImplementation
    case requestRefactor
    case applyRefactor
    case commitRefactor
    case verifyCleanWorktree
    case runUnitTests
}
```

## Run Snapshot (Persistence)

Store a snapshot per active run so app restart can resume safely.

```swift
struct LoopRunSnapshot: Codable, Sendable {
    let runID: UUID
    let projectID: UUID
    let queuedTicketIDs: [UUID]
    let completedTicketIDs: [UUID]
    let failedTicketID: UUID?
    let state: LoopRunState
    let updatedAt: Date
}
```

Start with JSON file persistence, then move into SwiftData model later.

## Manager Shape

Create `TicketLoopManager` actor with one active run per project.

```swift
actor TicketLoopManager {
    enum Event: Sendable {
        case stateChanged(projectID: UUID, state: LoopRunState)
        case ticketStarted(projectID: UUID, ticketID: UUID, index: Int, total: Int)
        case ticketFinished(projectID: UUID, ticketID: UUID, result: TicketResult)
        case cleanupStepStarted(projectID: UUID, ticketID: UUID, step: CleanupStep)
        case cleanupStepFinished(projectID: UUID, ticketID: UUID, step: CleanupStep, success: Bool, message: String?)
    }

    func start(projectID: UUID) async throws
    func pause(projectID: UUID) async
    func resume(projectID: UUID) async throws
    func cancel(projectID: UUID) async
    func state(projectID: UUID) -> LoopRunState
}
```

Keep orchestration in this actor only. UI reads events through `AsyncStream`, similar to existing `CodexManager`.

## Dependency Protocols

Use protocol seams so manager is testable and not tied to UI.

```swift
protocol TicketQueueProvider: Sendable {
    func topOpenTickets(projectID: UUID) async throws -> [TicketLoopItem]
}

protocol CodexTicketExecutor: Sendable {
    func execute(ticket: TicketLoopItem, project: LoopProjectContext) async throws -> CodexExecutionResult
}

protocol CleanupExecutor: Sendable {
    func run(step: CleanupStep, context: CleanupContext) async throws -> CleanupStepResult
}

protocol LoopSnapshotStore: Sendable {
    func load(projectID: UUID) async throws -> LoopRunSnapshot?
    func save(_ snapshot: LoopRunSnapshot) async throws
    func clear(projectID: UUID) async throws
}
```

`CodexManager` should be adapted behind `CodexTicketExecutor` so loop logic stays independent from sidecar details.

## Control Flow

Pseudo-flow for `start(projectID:)`:

1. Guard no active run for project.
2. Query ordered open tickets.
3. Build run snapshot (`preparingQueue` -> `running`).
4. For each ticket in order:
   1. set phase `.sendingToCodex`, send to Codex.
   2. set phase `.awaitingCodexResult`, await terminal result.
   3. if Codex failed: mark run failed and stop.
   4. run cleanup steps in configured order.
   5. if any cleanup step failed: mark run failed and stop.
   6. mark ticket complete, append to completed list, persist snapshot.
5. mark run completed and clear active snapshot.

## Terminal Result Requirement

Sequential behavior requires a terminal completion signal from Codex sidecar.

Current output lines alone are insufficient. Add a structured terminal event in sidecar protocol, for example:

```json
{"type":"ticket.completed","threadId":"<uuid>","success":true,"summary":"..."}
```

Without this, manager cannot reliably know when to run cleanup and advance.

## Failure Policy

- Codex failure: stop loop, keep run snapshot, require manual resume/retry.
- Cleanup failure: stop loop, keep failed step context.
- Cancel: cooperative cancellation; current step should finish or check cancellation boundaries.
- Pause: set pause intent and stop before next major phase boundary.

## Cleanup Pipeline Defaults

Use configurable step list per project, with defaults:

1. `commitImplementation`
2. `requestRefactor`
3. `applyRefactor`
4. `commitRefactor`
5. `verifyCleanWorktree`
6. `runUnitTests`

Each step should emit started/finished events and produce structured output for audit/debug.

## Integration Plan

1. Add `TicketLoopManager` actor in `TicketPartyUI/Support`.
2. Add protocol adapters:
   - SwiftData-backed `TicketQueueProvider` using existing order keys.
   - `CodexManager` adapter for execution and terminal results.
   - shell-backed `CleanupExecutor` for git/test steps.
3. Add loop view model (`@MainActor`) for UI state binding.
4. Add project-level "Run Loop / Pause / Resume / Cancel" controls.
5. Persist snapshots so interrupted loops can resume.

## Testing Strategy

Focus on unit tests (no UI tests):

1. happy path: 3 tickets, all cleanup steps pass -> completed.
2. Codex failure on ticket N -> run failed, N+1 not started.
3. cleanup failure on step K -> run failed with step context.
4. pause between tickets -> paused state and resumable index.
5. cancel during cleanup -> cancellation state and no next ticket.
6. restart from snapshot -> resumes at expected ticket/phase.
