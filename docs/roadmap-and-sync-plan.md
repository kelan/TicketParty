# TicketParty Roadmap and Sync Plan

## Delivery Strategy
Ship in milestones that preserve local-first operation while preparing for cross-device sync without custom server infrastructure.

## Milestone 0: Foundation (Week 1)
- Create project scaffolding: macOS SwiftUI app + shared domain package + CLI target.
- Define SwiftData schema for tasks, workflows, comments, notes, assignments, and task events.
- Define a shared persistence bootstrap used by app + CLI with an explicit store path:
- `~/Library/Application Support/TicketParty/TicketParty.store`.
- Seed one default workflow (`backlog -> ready -> in_progress -> review -> done`).
- Implement deterministic ticket IDs (`TT-1`, `TT-2`, ...).

## Milestone 1: MVP Issue Tracking (Weeks 2-3)
- Task CRUD with workflow-aware state transitions.
- Notes and structured comments.
- Assignment to named agents.
- Immutable event history for every significant mutation.
- Basic list/detail UI optimized for issue triage.

## Milestone 2: Agent-First CLI (Weeks 3-4)
- Implement `tp` commands for create/list/show/assign/transition/comments/questions.
- Add `--json` output to all read commands.
- Ensure CLI and app share validation logic and store.
- Build CLI with `swift-argument-parser`.
- Standardize subcommand flow: open shared container, create `ModelContext`, perform operation, save on writes.
- Add scripting docs for agent usage patterns.

## Milestone 3: "While You Were Away" Digest (Week 5)
- Session tracking markers (`inactive`, `active`, `digest viewed`).
- Digest query service and summary UI panel.
- Highlight unresolved agent questions and newly closed tasks.
- Add CLI digest command for terminal-based review.

## Milestone 4: Workflow Customization (Week 6)
- UI for creating/editing workflow states and transitions.
- Guard against deleting states referenced by active tasks.
- Migration behavior for workflow edits.
- Transition history and reporting by workflow.

## Milestone 5: Hardening and v1 Release (Weeks 7-8)
- Backup/export (`jsonl` or SQLite snapshot).
- Error handling and recovery paths for corrupted metadata.
- Test coverage expansion for edge-case transitions and race scenarios.
- Performance pass for large historical datasets.

## Sync Plan (Near-Future, No Custom Backend)

## Goal
Sync across user-owned Apple devices (Mac + iPhone) while avoiding a custom cloud API.

## Recommended Approach
- Use SwiftData with CloudKit-backed syncing for private user data.
- Keep one shared model container configuration that can run:
- Local-only mode (default during early development).
- CloudKit sync mode when enabled.

## Why This Fits
- No custom server or web API required.
- Works naturally for single-user private data replicated across devices.
- Preserves local-first reads/writes with background sync semantics.

## Data Modeling for Sync Readiness (Start Now)
- Use UUID primary IDs for all records.
- Keep immutable event IDs and timestamps for conflict traceability.
- Avoid business logic tied to local auto-increment IDs.
- Store derived presentation fields (like `TT-42`) but compute from stable primitives when possible.

## Conflict Strategy
- Canonical history comes from append-only `TaskEvent`.
- For conflicting mutable fields:
- Use deterministic merge rules by field (for example, last-write-wins for title, explicit conflict note for state if transition invalid).
- If needed, append system-generated conflict comments for owner review.

## iPhone App Preparation
- Move domain logic into shared package now.
- Build macOS and iOS app targets against same core modules.
- Keep UI-specific logic platform-local, model and services shared.
- Add responsive list/detail patterns that work on iPhone navigation stacks.

## Migration Plan to Sync
- Phase A: launch local-only with sync-safe IDs and event model.
- Phase B: enable CloudKit-backed container behind feature flag.
- Phase C: dogfood on two devices, observe merge behavior and digest correctness.
- Phase D: ship user-facing sync toggle and sync diagnostics panel.

## Risks and Mitigations
- Risk: workflow edits can break task transitions on another device.
- Mitigation: version workflows and keep compatibility resolver on load.
- Risk: event log growth affects performance.
- Mitigation: add indexed queries and precomputed digest snapshots while retaining raw history.
- Risk: CLI and app divergence.
- Mitigation: force all writes through shared domain service.

## Initial Backlog Proposal
- `P0`: model schema + event logging + state engine.
- `P0`: task list/detail UI + notes/comments.
- `P0`: `tp` CLI create/list/show/assign/transition.
- `P1`: digest engine + unanswered questions queue.
- `P1`: workflow editor.
- `P2`: CloudKit sync flag and device sync test harness.
