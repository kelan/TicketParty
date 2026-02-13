# TT-60 Plan: Play Alert Sound When a Task Finishes

## Summary

Add an audible alert when a ticket task reaches terminal state (`success` or `failure`), with deduplication so one completion produces one sound.

## Scope

In scope:

1. Direct ticket runs started from conversation send flow.
2. Loop-driven ticket runs (start loop / run primary action).
3. Success and failure both trigger a completion sound.

Out of scope (for this ticket):

1. Per-cleanup-step sounds (would be noisy).
2. OS notification banners.
3. User-configurable sound preferences.

## Current Behavior (Code Paths)

1. Direct completion handling lives in `CodexViewModel.applyTicketCompletion(...)`.
2. Loop completion handling arrives via `CodexViewModel.consumeLoopEvent(...)` with `.ticketFinished`.
3. Duplicate completion signals are possible because completion can be inferred from streamed output (`agentTicketCompletion`) and also received as explicit terminal events (`.ticketCompleted`).

Relevant files:

- `TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift`
- `TicketPartyPackage/Sources/TicketPartyUI/Support/TicketLoopManager.swift`
- `TicketPartyPackage/TicketPartyTests/TicketPartyTests.swift`

## Design

### 1. Introduce a sound alert abstraction

Add a small `TaskCompletionAlerting` protocol in the UI support layer and inject it into `CodexViewModel`.

- Default implementation: system beep (AppKit `NSSound.beep()` on macOS).
- Test implementation: recorder stub to assert call count and payload.

This keeps playback logic isolated and testable.

### 2. Trigger from terminal completion points only

Trigger sound from the same places that currently transition tickets out of sending state:

1. `applyTicketCompletion(ticketID:success:summary:)`
2. `consumeLoopEvent` case `.ticketFinished`

### 3. Deduplicate notifications

Only play sound when the ticket was actively sending just before terminal transition.

Rule:

- Compute `wasSending = (ticketIsSending[ticketID] == true)` before clearing sending state.
- Play alert only when `wasSending == true`.

This prevents double sounds from duplicate terminal signals and from overlapping manager/loop event streams.

## Implementation Plan

1. Add `TaskCompletionAlerting` protocol + default macOS implementation in `TicketPartyUI/Support`.
2. Inject alert dependency into `CodexViewModel` initializer with a default value.
3. Update direct completion flow (`applyTicketCompletion`) to:
   - gate by `wasSending`
   - play sound once on completion.
4. Update loop completion flow (`consumeLoopEvent` `.ticketFinished`) with the same gating rule.
5. Keep existing status/error/transcript behavior unchanged.

## Test Plan

Unit tests in `TicketPartyPackage/TicketPartyTests/TicketPartyTests.swift`:

1. `codexViewModel_taskCompletionAlert_playsOnceForTerminalCompletion`
   - simulate terminal completion path
   - verify one alert call.
2. `codexViewModel_taskCompletionAlert_doesNotPlayWhenNotSending`
   - verify no alert when completion arrives for non-active ticket.
3. `codexViewModel_taskCompletionAlert_deduplicatesRepeatedTerminalSignals`
   - verify repeated completion for same ticket only alerts once.

Validation commands:

1. `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -configuration Debug build`
2. `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test -only-testing:TicketPartyTests`

## Risks and Mitigations

1. Risk: duplicate sounds due to multiple completion event sources.
   - Mitigation: `wasSending` gate.
2. Risk: alert fired too frequently during loop cleanup internals.
   - Mitigation: trigger only at ticket terminal boundary (`ticketFinished`), not cleanup step events.
3. Risk: future preference support requires refactor.
   - Mitigation: protocol-based alert abstraction now.

## Open Questions

1. Should failure use a different sound than success, or is one sound acceptable for both?
2. Should alerts fire while app is frontmost only, or always?
3. Do we want a Settings toggle for this now, or in a follow-up ticket?
