# TicketParty Product Plan

## Vision
Build a local-first macOS ticket tracker that behaves like a lightweight bug tracker for human + LLM agent collaboration.
This is not single-person TODO app.

## Product Goals
- Track work items with rich lifecycle states, ownership, notes, comments, and immutable history.
- Make delegation to coding agents easy through structured ticket data and CLI access.
- Provide a clear "what happened while I was away" overview when returning to the computer.
- Keep all primary data local first, with future Apple-device sync support.

## Primary Users
- `Owner`: the human who defines workflows, delegates work, and resolves blockers.
- `Agent`: LLM-driven worker that executes tickets, posts updates, and asks clarifying questions.

## Core Use Cases
- Create and triage tickets in a customizable workflow.
- Assign tickets to named agents and track current assignee + handoffs.
- Agents can add follow-up tickets or sub-tickets as they do their planning.
- Agents can add notes to tickets for enduring context and implementation details.
- Use comments as a conversation thread between owner and agents.
- Mark agent questions explicitly so unanswered blockers are visible.
- Review a digest of all ticket activity since last active session.
- Query and update tickets from CLI for agent automation.

## Ticket Model Requirements
- Tickets resemble issue tracker tickets:
- Stable ID (`TT-123` style), title, description, severity/size, workflow/state, assignee, timestamps.
- Ticket-level notes for long-form evolving context.
- Comments with lightweight structure:
- `type`: update, question, answer, decision, status-change.
- Optional `inReplyTo` to support threaded Q/A without heavy nesting.
- Optional `requiresResponse` and `resolvedAt` to track open questions.
- Immutable event history for all state and field changes.

## Workflow Requirements
- Workflow definitions are user-configurable.
- Each workflow contains named states and allowed transitions.
- Tickets reference workflow + current state.
- State transitions are validated both in app UI and CLI.

## "While You Were Away" Overview
- Show a time-bounded activity summary (default since last app active time).
- Include:
- Tickets created/closed/reopened.
- State transitions.
- Agent updates and unresolved questions.
- New blockers and tickets needing owner input.
- Provide quick actions: open ticket, answer question, approve/redirect work.

## CLI Requirements
- First-class command line interface for agents, designed as a practical `bd` alternative.
- Binary name: `tp`.
- Core commands:
- `tp ticket create`, `tp ticket list`, `tp ticket show`, `tp ticket assign`, `tp ticket move-state`.
- `tp note add`, `tp comment add`, `tp question ask`, `tp question answer`.
- `tp digest since --last-active`.
- Output modes:
- Human-readable tables.
- JSON mode for programmatic agents.
- Favor stable IDs and deterministic output for automation.
- CLI and app must use one shared persistence bootstrap and one shared SwiftData store path.
- Planned store path: `~/Library/Application Support/TicketParty/TicketParty.store`.
- CLI implementation pattern should be deterministic per command:
- Open shared container.
- Create `ModelContext`.
- Execute operation.
- Save on write commands.

## Non-Goals (Initial)
- No multi-user remote collaboration service.
- No web app or public API.
- No required external cloud backend for core operation.

## Success Criteria (MVP)
- Owner can define at least one custom workflow.
- Agent can complete a full ticket lifecycle from CLI.
- Owner can return after absence and immediately see unresolved questions and completed work.
- All significant changes are queryable from immutable history.
