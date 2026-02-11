# Streaming Sidecar Integration: App + Supervisor Updates

## Purpose

Define the code changes needed so TicketParty can consume in-flight Codex output (not just final turn output) while a task is running.

This document assumes the sidecar is updated to emit newline-delimited JSON (NDJSON) streaming frames such as:

- `ticket.started`
- `ticket.output`
- `codex.event` (optional passthrough)
- `ticket.completed` (terminal, exactly once)

## Current State (as of now)

- App-side streaming exists only for raw process stdout/stderr lines from a locally spawned sidecar process.
  - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift`
- `codex-supervisor` currently only supports a `hello` handshake over unix socket.
  - `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/codex-supervisor/main.swift`
- There is no implemented `sendTicket` or event subscription API in supervisor yet.

## Target End-to-End Flow

1. App opens a long-lived subscription connection to supervisor for streamed events.
2. App sends `sendTicket` request to supervisor with `projectID`, `ticketID`, `requestID`, `prompt`.
3. Supervisor ensures/starts worker sidecar for that project.
4. Supervisor forwards ticket command to sidecar stdin.
5. Sidecar emits NDJSON frames while running.
6. Supervisor parses frames and forwards normalized events to subscribed app client(s).
7. App updates per-ticket output incrementally until `ticket.completed` arrives.

## Protocol Changes (Supervisor Socket)

Keep the existing unix socket transport and newline-delimited JSON framing.

### App -> Supervisor requests

- `hello`
- `subscribe` (keeps socket open)
- `sendTicket`
- `workerStatus`
- `stopWorker`

Example `sendTicket` request:

```json
{"type":"sendTicket","projectID":"<uuid>","ticketID":"<uuid>","requestID":"<uuid>","workingDirectory":"/path","prompt":"..."}
```

### Supervisor -> App responses/events

- request replies: `*.ok` or `error`
- streamed events (over `subscribe` channel):
  - `worker.started`
  - `ticket.started`
  - `ticket.output`
  - `ticket.error`
  - `ticket.completed`
  - `worker.exited`

### Required invariants

- `ticket.completed` is emitted exactly once per `requestID`.
- Events for a ticket preserve order.
- `requestID`, `projectID`, and `ticketID` are present on all ticket events.

## Supervisor Code Updates

File: `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/codex-supervisor/main.swift`

### 1. Expand control request model

Add request payload structs for:

- `subscribe`
- `sendTicket(projectID, ticketID, requestID, workingDirectory, prompt)`
- `workerStatus`, `stopWorker`

Add typed responses/events instead of only `hello.ok`.

### 2. Add app subscriber registry

Maintain a list of connected subscriber sockets (`subscribe` calls). Each event broadcast writes one JSON line to each live subscriber.

- Remove dead subscribers on write failure.
- Keep writes serialized on supervisor queue.

### 3. Add worker session map

Maintain `projectID -> WorkerSession` with:

- `Process`
- `stdin` writer
- stdout/stderr read handlers
- line buffers for chunked reads
- worker state (starting/running/stopped/error)

### 4. Implement `sendTicket`

On `sendTicket`:

1. Validate payload.
2. Ensure worker exists for project (spawn lazily if missing/dead).
3. Write NDJSON command line to worker stdin.
4. Reply immediately with `sendTicket.ok` (do not wait for completion).

### 5. Parse sidecar NDJSON frames

For worker stdout:

- Parse one JSON object per line.
- Validate required fields (`type`, `requestID`, etc).
- Normalize to supervisor event shape.
- Broadcast to subscribers.

For stderr:

- Emit `ticket.error` (best-effort association by active request map per project).

### 6. Track active requests

Maintain `requestID -> (projectID, ticketID)` and per-project current request queue policy.

- If only one in-flight request per project is allowed, reject/queue subsequent sends.
- On `ticket.completed`, clear in-flight state.

### 7. Backpressure and robustness

- If app subscriber is slow, drop subscriber connection instead of blocking worker reads.
- Use bounded line length and reject malformed frames.
- Emit `worker.exited` on process termination.

### 8. Protocol version bump

Bump supervisor protocol version from `1` to `2` once streaming APIs are added.

Also update health-check handshake minimum protocol expectations.

## App Code Updates

Primary file: `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift`

### 1. Replace direct sidecar spawning in app

Current app manager owns sidecar `Process` directly. Move process ownership to supervisor.

`CodexManager` should become a supervisor client that:

- opens socket connection(s)
- sends control requests
- consumes streamed events
- maps them to `CodexManager.Event`

### 2. Add supervisor client layer

Add internal client helper for:

- request/response RPC over unix socket
- long-lived `subscribe` stream reader
- automatic reconnect (with bounded retry)

### 3. Correlate request IDs to tickets

In `sendTicket(...)`:

- generate `requestID`
- store `requestID -> ticketID`
- send `sendTicket` to supervisor

On stream events:

- route `ticket.output` to the matching ticket buffer
- route `ticket.error` to ticket error state
- treat `ticket.completed` as terminal for spinner/state

### 4. Update manager event model

Add a terminal event so loop orchestration can advance without parsing output text:

- `ticketCompleted(ticketID: UUID, success: Bool, summary: String?)`

Keep existing output/error events for UI rendering.

### 5. Update view-model sending lifecycle

File: `/Users/kelan/Projects/TicketParty/TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift` (`CodexViewModel` section)

- Set `ticketIsSending[ticketID] = true` at request submit.
- Clear sending only when `ticket.completed` or terminal failure is received.
- Do not clear sending immediately after write succeeds.

### 6. Parsing rules in app

- Parse supervisor stream as JSON lines.
- Ignore unknown event types (forward-compatible).
- Handle malformed frame as non-fatal stream error and continue.

## Suggested Event Payload Shape

```json
{"type":"ticket.output","projectID":"...","ticketID":"...","requestID":"...","text":"..."}
{"type":"ticket.completed","projectID":"...","ticketID":"...","requestID":"...","success":true,"summary":"..."}
```

## Rollout Plan

1. Implement sidecar streaming frames (`runStreamed` based).
2. Add supervisor `sendTicket` + `subscribe` + worker management.
3. Migrate `CodexManager` to supervisor client mode.
4. Update `CodexViewModel` to rely on terminal events.
5. Remove/guard old direct-sidecar path.

## Test Plan

### Supervisor tests

- Parses fragmented stdout chunks into complete JSON frames.
- Broadcasts ordered events to subscribers.
- Emits exactly one terminal `ticket.completed` per request.
- Handles worker exit and malformed output without crashing.

### App manager tests

- `sendTicket` maps `requestID -> ticketID` correctly.
- Incremental `ticket.output` appends as frames arrive.
- `ticketIsSending` remains true until `ticket.completed`.
- Reconnect behavior re-subscribes and resumes event consumption.

## Notes

- Keep stdout protocol strictly machine-readable NDJSON; avoid free-form log lines on stdout.
- If human logs are needed, write them to stderr or dedicated log files.
- This design is compatible with the existing ticket-loop plan that requires explicit terminal completion.
