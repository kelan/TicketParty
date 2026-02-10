# Codex Sidecar Integration Plan

## Goal
Enable "send ticket to Codex" from the app, with one long-lived Codex sidecar process per project, project-scoped working directories, and visible Codex output in ticket details.

## Scope for Phase 2 (Implementation)
1. Launch and manage one sidecar subprocess per project.
2. Add optional project working directory (`workingDirectory`), but block Codex start when missing.
3. Send newline-delimited JSON commands over sidecar stdin.
4. Parse newline-delimited JSON responses from sidecar stdout.
5. Add UI:
   - Sidebar status entry for Codex.
   - "Send to Codex" button in ticket detail panel.
   - Output text area at bottom of ticket detail panel.

## Non-goals (for first pass)
- Persisting Codex transcripts to SwiftData.
- Multi-turn chat UI.
- Automatic retries/backoff beyond explicit "send" action.
- Rich protocol features not required for sending one ticket command.

## Current Code Touch Points
- App bootstrap: `App/TicketPartyApp.swift`
- Root navigation/sidebar: `TicketPartyPackage/Sources/TicketPartyUI/ContentView.swift`
- Project detail + ticket detail panel: `TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift`
- Sidebar/draft support: `TicketPartyPackage/Sources/TicketPartyUI/Support/NavigationAndDrafts.swift`
- SwiftData model: `TicketPartyPackage/Sources/TicketPartyDataStore/StoreModels.swift`
- Shared schema/container: `TicketPartyPackage/Sources/TicketPartyDataStore/Persistence.swift`

## Data Model Changes
### Project
Add an optional working directory:
- Field: `workingDirectory: String?`
- Default: `nil`
- Validation: no hard validation on save; validate on Codex start.

### UI Draft Model
Extend `ProjectDraft` with:
- `workingDirectory: String`
- `normalizedWorkingDirectory: String?` (trimmed, empty -> `nil`)

Project create/edit flows should read/write this field.

## Runtime Architecture
Create a dedicated actor: `CodexManager`.

### Responsibilities
- Maintain process sessions keyed by `projectID`.
- Start sidecar for a project on demand.
- Keep stdin/stdout handles alive.
- Serialize outbound command writes.
- Read/parse stdout lines and route responses to ticket output buffers.
- Publish status/output snapshots for UI.

### Core Types
- `CodexProjectStatus`: `stopped`, `starting`, `running`, `error(String)`
- `CodexSession`:
  - `process: Process`
  - `stdin: FileHandle`
  - `stdoutTask: Task<Void, Never>`
  - `stderrTask: Task<Void, Never>` (optional but recommended for diagnostics)
- `CodexTicketLog`: in-memory per ticket accumulated text
- `PendingRequest`: map request id -> `(projectID, ticketID, sentAt)`

### Sidecar Launch
- Executable: `node` (via `/usr/bin/env` + `node` argument for reliability)
- Arg 1: expanded path for `~/dev/codex-sidecar/sidecar.mjs`
- `Process.currentDirectoryURL`: expanded and validated project `workingDirectory`
- `stdin/stdout/stderr`: `Pipe`

Validation before launch:
1. Project has non-empty `workingDirectory`.
2. Path exists and is a directory.
3. Sidecar script path exists.

If validation fails, return user-visible error and do not spawn process.

### JSON I/O Contract
Use newline-delimited JSON (JSONL):
- One command object per line written to stdin.
- One response object per line read from stdout.

Implementation notes:
- `JSONEncoder` for command structs.
- Append `\n` after each encoded object.
- Read stdout as bytes -> split lines -> decode each line with `JSONDecoder`.
- Handle malformed lines by appending a parse error to project/ticket output and keeping session alive.

Protocol payloads should match the sidecar's expected "standard Codex JSON command format". We will model the exact schema in Swift once we wire implementation (request id, command type, and command payload fields).

## UI Plan
### 1) Sidebar Codex Entry
Add `SidebarSelection.codex`.

Sidebar top section order:
1. Activity
2. All Projects
3. Codex

Codex detail screen (`CodexStatusView`) shows per-project:
- Project name
- Status badge (stopped/starting/running/error)
- Last error (if any)

### 2) Project Editor: Working Directory
In `ProjectEditorSheet`:
- Add `TextField("Working Directory", ...)` in Basics or a new "Codex" section.
- Helper text: "Required to run Codex for this project."

### 3) Ticket Detail: Send + Output
In `ProjectTicketDetailPanel`:
- Add `Button("Send to Codex")`.
- Button action sends selected ticket context via `CodexManager`.
- If project working dir is missing/invalid, show inline error text in panel.
- Add bottom output area:
  - Read-only `TextEditor` (or scrollable monospaced `Text`) bound to ticket output log.
  - Keep latest response visible for selected ticket.

## Dependency Injection / State Flow
Actors are not directly bindable in SwiftUI. Use a bridge object:
- `@MainActor final class CodexViewModel: ObservableObject`
  - `@Published var projectStatuses: [UUID: CodexProjectStatus]`
  - `@Published var ticketOutput: [UUID: String]`
  - `@Published var ticketErrors: [UUID: String]`
- `CodexViewModel` owns/uses `CodexManager` and exposes async methods:
  - `sendTicket(ticket: Ticket, project: Project)`
  - `status(for projectID: UUID)`
  - `output(for ticketID: UUID)`

Inject once from app root into `TicketPartyRootView` via `.environmentObject(...)`.

## Command Payload for "Send Ticket"
First command shape for sidecar send:
- include ticket id/display id
- title
- description
- priority/severity
- project id/name

Manager behavior:
1. Ensure session for project is running (start lazily if needed).
2. Encode request JSON.
3. Write command line to stdin.
4. Track pending request id -> ticket id.
5. Route sidecar responses back into that ticket's output buffer.

## Error Handling Strategy
- Startup errors: missing working dir, invalid path, sidecar launch failures.
- Runtime errors: broken pipe, process exit, decode failures.
- For exited process:
  - mark status `error(...)`
  - clear session
  - next send attempts restart

User-facing policy:
- keep errors non-blocking except missing/invalid working dir
- always surface latest error in panel and Codex status view

## Testing Plan (Phase 2)
1. Unit tests for project working directory normalization.
2. Unit tests for launch validation logic (missing path, non-directory, missing sidecar script).
3. Unit tests for newline JSON encode/decode helpers.
4. Integration-style tests with a fake process adapter (preferred) or fixture pipes to verify:
   - lazy start once per project
   - command write per send
   - response routing to correct ticket output
   - restart after process death

## Implementation Sequence (Phase 2)
1. Add `Project.workingDirectory` and wire create/edit UI.
2. Add sidebar `codex` selection + status screen scaffold.
3. Add `CodexManager` actor + `CodexViewModel` bridge.
4. Implement sidecar process lifecycle and JSONL I/O.
5. Add "Send to Codex" button and output area in ticket detail panel.
6. Wire errors/status into UI.
7. Add tests and run quality gates.

## Open Items to Confirm Before/While Implementing
- Exact sidecar request/response JSON schema field names.
- Whether stderr should be merged into ticket output or shown separately.
- Whether ticket output should persist to store (plan assumes in-memory for first pass).
- Whether "Send to Codex" should include prior comments/history or only current ticket fields.
