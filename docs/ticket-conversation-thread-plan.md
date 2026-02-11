# Ticket Conversation Threads With Plan/Implement Mode (Manual Sends v1)

## Summary

Implement a persistent per-ticket conversation thread so each ticket supports multi-turn back-and-forth with Codex, including follow-up questions, replayed context on every future send, and a ticket-level mode toggle (`Plan` vs `Implement`).
v1 scope is manual ticket sends in the ticket detail panel; run-loop behavior stays unchanged.

## Scope

- In scope: manual conversation in `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift`.
- In scope: persistent thread storage, replay builder, mode toggle, and explicit “Start Implementation” action.
- In scope: continue writing raw run transcripts via `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyDataStore/TicketTranscriptStore.swift`.
- Out of scope (v1): applying thread replay/mode to automated loop tasks.

## Public/Interface Changes

### Models (`/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyModels/Models.swift`)

Add:

- `TicketConversationMode`: `plan`, `implement`
- `TicketConversationRole`: `user`, `assistant`, `system`
- `TicketConversationMessageStatus`: `pending`, `streaming`, `completed`, `failed`, `cancelled`

### SwiftData schema (`/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyDataStore/StoreModels.swift`)

Add:

- `TicketConversationThread`
- `id: UUID` (unique)
- `ticketID: UUID` (unique)
- `modeRaw: String`
- `rollingSummary: String`
- `lastCompactedSequence: Int64`
- `createdAt: Date`
- `updatedAt: Date`
- `TicketConversationMessage`
- `id: UUID` (unique)
- `threadID: UUID`
- `ticketID: UUID`
- `sequence: Int64`
- `roleRaw: String`
- `statusRaw: String`
- `content: String`
- `requiresResponse: Bool`
- `runID: UUID?`
- `createdAt: Date`
- `updatedAt: Date`

Update schema registration in `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyDataStore/Persistence.swift` to include both new models.

### Data-store API (`/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyDataStore/TicketConversationStore.swift`)

Add a new store with methods:

- `ensureThread(ticketID:)`
- `mode(ticketID:)`
- `setMode(ticketID:mode:)`
- `appendUserMessage(ticketID:text:)`
- `beginAssistantMessage(ticketID:runID:)`
- `appendAssistantOutput(ticketID:line:)`
- `completeAssistantMessage(ticketID:success:errorSummary:)`
- `messages(ticketID:)`
- `replayBundle(ticketID:windowCount:maxSummaryChars:) -> (mode, summary, messages)`
- `compactIfNeeded(ticketID:windowCount:maxSummaryChars:)`

## Runtime Design

### Send flow

1. User types a message in ticket conversation composer.
2. Persist user message first (`status = completed`).
3. Start transcript run (existing `TicketTranscriptStore` behavior).
4. Create assistant placeholder message (`status = streaming`, empty content).
5. Build replay prompt from:
- ticket title/description
- mode instruction (`Plan` or `Implement`)
- rolling summary
- recent window messages
- new user message
6. Call existing `CodexManager.sendTicket(...)` with composed prompt.
7. Stream `ticket.output` lines into:
- transcript file (existing)
- assistant streaming message content (new)
8. On terminal event, mark assistant message `completed` or `failed`, set `requiresResponse` using deterministic heuristic (`content` contains at least one `?` in the tail segment), and finalize transcript run.

### Replay strategy (locked)

- Use `window + summary`.
- Defaults:
- `windowCount = 12` latest messages
- `maxSummaryChars = 12_000`
- Compaction algorithm is extractive and deterministic:
- move older messages outside window into `rollingSummary` as role-prefixed lines
- cap each compacted line (for example 500 chars) and drop oldest summary lines if summary cap is exceeded

### Mode behavior (locked)

- Mode is stored per ticket thread.
- `Plan` mode injects a strict preamble: planning/design only, no implementation actions.
- `Implement` mode injects implementation preamble.
- Mode is sticky across app restarts.

### Start Implementation action (locked)

- Visible when mode is `Plan`.
- On click:
1. Set mode to `Implement`.
2. Append a system message: mode switched.
3. Auto-send a synthesized handoff user message built from rolling summary + latest thread context.
4. This is explicit and user-triggered (no keyword auto-switch).

## UI Changes

### Ticket detail panel (`/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift`)

Replace one-way codex interaction with:

- Conversation timeline (user/assistant/system bubbles or rows with timestamps).
- Composer (`TextEditor` + `Send`).
- Mode segmented control (`Plan` / `Implement`).
- `Start Implementation` button (Plan mode only).
- Existing `Stop` action retained when a send is active.
- Existing raw output view moved behind a `DisclosureGroup("Raw Transcript")` for debugging.

### View-model changes (`/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift`)

Add:

- `sendMessage(ticket:project:text:)`
- thread-loading state for selected ticket
- mapping from active ticket to active assistant message/run
Keep existing loop APIs unchanged.

## Supervisor/Protocol Impact

- No protocol format change required for v1.
- Continue using current `submitTask` + streamed `ticket.output` / `ticket.completed` events from `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/codex-supervisor/main.swift`.
- Thread replay is app-side prompt composition.

## Migration and Compatibility

- Additive schema migration only (new models/tables).
- Existing tickets without thread rows are lazily initialized on first conversation interaction.
- Existing `send(ticket:project:)` remains as compatibility wrapper:
- behavior: treat as sending a generated user message from ticket title/description when needed by existing callers.

## Test Plan

### Unit tests (`/Users/kelan/Projects/TicketPartyPackage/TicketPartyTests/TicketPartyTests.swift`)

Add tests for:

- thread creation and mode persistence
- message append ordering via `sequence`
- replay bundle correctness (`summary + last window`)
- compaction boundaries and summary cap
- assistant streaming aggregation from multiple output lines
- terminal success/failure updates to message/transcript state
- “Start Implementation” flips mode and emits synthesized handoff message

### Integration-style behavior tests

Add deterministic view-model tests (with stubbed manager stream) for:

- back-and-forth conversation over multiple sends
- app restart reloads persisted thread and replays correctly on next send
- active-send interruption marks assistant message failed/cancelled and keeps history intact

### Non-goals for test execution

- No UI tests required for this feature.
- Build + unit tests only via:
- `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -configuration Debug build`
- `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test -only-testing:TicketPartyTests`

## Rollout Steps

1. Add new models/enums/store and register schema.
2. Add replay/compaction engine and mode preamble builder.
3. Add conversation persistence wiring in `CodexViewModel`.
4. Update ticket detail UI to conversation-first layout.
5. Keep legacy raw output visible under disclosure.
6. Add unit tests and run build + unit test commands.
7. Add docs entry at `/Users/kelan/Projects/TicketParty/docs/ticket-conversation-thread-plan.md` during implementation.

## Assumptions and Defaults

- Existing working-tree changes in `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift` are treated as current baseline.
- v1 applies to manual ticket sends only.
- Replay uses deterministic extractive summary (no extra model call).
- Follow-up question detection is heuristic (`?` in assistant tail text) for UI signaling only.
- Transcript logs remain the authoritative raw stream artifact; conversation messages are user-facing structured history.
