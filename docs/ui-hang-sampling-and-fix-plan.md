# UI Hang Sampling and Fix Plan (Project/Ticket Switching)

## Goal

Reduce or eliminate UI hangs when switching between projects and tickets, with focus on large ticket conversation history and transcript size.

## Current High-Risk Hotspots

1. Main-actor synchronous conversation load on selection:
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift:722`
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift:1209`
2. Full conversation fetch (`messages`) for selected ticket:
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyDataStore/TicketConversationStore.swift:165`
3. Transcript disk read during detail render path:
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift:850`
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift:1469`
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyDataStore/TicketTranscriptStore.swift:142`
4. Per streamed line: append assistant output + refetch full message array:
   - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift:1505`

## Phase 1: Sampling and Repro (No Behavioral Change)

1. Repro with two fixtures:
   - medium thread (~100 messages, multi-kilobyte assistant messages)
   - heavy thread (~500+ messages and/or very large assistant content)
2. Capture 3 samples during visible stall while switching ticket/project:
   - Activity Monitor -> TicketParty process -> Sample Process (10s each)
3. In Xcode Instruments (Time Profiler):
   - record selection switches for ~60s
   - enable “Record Waiting Threads”
4. Add temporary timing logs around:
   - `CodexViewModel.loadConversation`
   - `TicketConversationStore.messages`
   - `CodexViewModel.outputSnapshot`
   - Detail panel render-driven transcript snapshot call
5. Save evidence in a short note:
   - top 5 hottest stacks
   - p50/p95 timing for load and switch
   - ticket data size at time of hang

## Phase 2: Fast, Low-Risk Mitigations

1. Gate transcript loading to expanded state only:
   - only call `outputSnapshot` when `isRawTranscriptExpanded == true`
2. Move conversation load off the main actor:
   - run store fetch on background task/actor
   - publish result back on `@MainActor`
3. Cap initial message load for UI:
   - add `messages(ticketID:limit:)` and load latest N (for example 100) on switch
4. Debounce selection-triggered load:
   - cancel in-flight load task when ticket changes quickly

## Phase 3: Structural Performance Fixes

1. Stop refetching full message history on each streamed line:
   - update only active streaming message in memory
   - persist incrementally in store, but avoid `messages(...)` round-trip each line
2. Add message preview/body strategy:
   - list view uses truncated preview text
   - full text loaded lazily when needed
3. Keep bounded in-memory cache:
   - per-ticket LRU for conversation arrays
   - evict non-selected tickets aggressively
4. Consider batching assistant output writes:
   - coalesce line appends with short flush interval (e.g. 100-250ms)

## Phase 4: Verify and Guardrails

1. Validate with original heavy fixture and real-world long threads.
2. Add unit tests for:
   - limited message fetch ordering
   - background load cancellation correctness
   - transcript loading only when disclosure is expanded
3. Add lightweight performance test target assertions:
   - ticket switch operation should complete under agreed threshold on fixture data

## Success Criteria

1. No visible UI hangs while switching between projects/tickets in heavy fixture.
2. `loadConversation` p95 under 100ms for medium fixture and under 250ms for heavy fixture.
3. No regression in conversation correctness (mode, ordering, streaming completion state).

## Implementation Order

1. Transcript disclosure gating
2. Async/cancellable conversation load
3. Limited message fetch API
4. Streaming path refactor to avoid full refetch per line
5. Cache/preview optimizations only if needed after re-sampling
