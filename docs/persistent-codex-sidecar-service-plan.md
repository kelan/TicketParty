# Persistent Codex Sidecar Service Plan

## Decision

Use a long-lived **Codex Supervisor** process outside the app.  
The app should not directly own one sidecar `Process` per project.

Why:

- App restarts should not kill active ticket work.
- Reconnect logic is centralized in one place.
- Project sidecar count remains dynamic and supervisor-managed.
- Recovery is simpler than re-attaching many app-owned child processes.

## Recommended Topology

1. `TicketParty.app` (UI + orchestration intent)
2. `codex-supervisor` (persistent control plane)
3. Per-project `codex-sidecar` workers (spawned on demand by supervisor)

So you keep "1 process per project" behavior, but it is owned by the supervisor, not by the app.

## Persistence Model

Store runtime records in:

`~/Library/Application Support/TicketParty/runtime/`

Files:

- `supervisor.json`
- `workers/<project-id>.json`

`supervisor.json` should include:

- `pid`
- `startedAt` (epoch ms)
- `protocolVersion`
- `binaryPath`
- `binaryHash` (optional, recommended)
- `controlEndpoint` (XPC service name or unix socket path)
- `instanceToken` (random UUID generated at launch)

Each worker record should include:

- `projectID`
- `workerPID`
- `threadMap` summary (optional)
- `workingDirectory`
- `startedAt`
- `status`

## Reconnect/Validation Strategy

Do not trust PID alone. Validate identity with a handshake.

Validation steps on app launch:

1. Read `supervisor.json`.
2. Check process existence (`kill(pid, 0)`).
3. Connect to `controlEndpoint`.
4. Send `hello` with expected `instanceToken` and minimum protocol.
5. Require supervisor response with:
   - same `instanceToken`
   - matching protocol
   - live status + worker list.
6. If any step fails:
   - treat record as stale,
   - delete/reap runtime record,
   - start a new supervisor.

This avoids PID reuse bugs and stale socket/path issues.

## Control Protocol (App <-> Supervisor)

Use a small structured protocol (XPC preferred on macOS, unix socket acceptable).

Commands:

- `hello`
- `ensureWorker(projectID, workingDirectory)`
- `sendTicket(projectID, ticketID, prompt)`
- `workerStatus(projectID)`
- `listWorkers()`
- `stopWorker(projectID)`
- `shutdownSupervisor(graceful: Bool)`

Events streamed back to app:

- `worker.started`
- `ticket.output`
- `ticket.error`
- `ticket.completed` (required for loop advancement)
- `worker.exited`

## Supervisor Responsibilities

1. Start lazily on first app request, or auto-start at app launch.
2. Maintain in-memory map `projectID -> worker session`.
3. Spawn worker when `ensureWorker`/`sendTicket` arrives for missing worker.
4. Route stdout/stderr and terminal completion events.
5. Keep workers alive across app reconnects.
6. Garbage collect idle workers via timeout policy (optional initially).

## Startup and Lifecycle Options

### Option A (Recommended): LaunchAgent

Use `launchd` user agent for supervisor with `KeepAlive`.

Pros:

- Native macOS lifecycle management.
- Clean restart semantics.
- No manual daemonization tricks.

Cons:

- Extra setup/plist management.

### Option B: App-launched detached process

App launches supervisor in background and writes `supervisor.json`.

Pros:

- Faster first implementation.

Cons:

- More edge cases around orphaning, restart, and login lifecycle.

## Suggested Rollout

### Phase 1: Minimal Persistent Supervisor

1. Build `codex-supervisor` executable target.
2. Move current sidecar spawn/write/read logic out of app `CodexManager`.
3. Add app control client with `hello` + reconnect flow.
4. Add `ticket.completed` terminal event requirement.
5. Use json runtime files and stale-record reap.

### Phase 2: Robust Lifecycle

1. Move startup to `launchd` LaunchAgent.
2. Add worker idle shutdown policy.
3. Add restart backoff policy for flapping workers.
4. Add protocol versioning and compatibility checks.

### Phase 3: Observability

1. Structured logs per supervisor + worker.
2. Last-known run metadata for resumed ticket loops.
3. Supervisor health endpoint in Codex status UI.

## Failure Handling Rules

- **Supervisor down**: app attempts one restart, then surfaces actionable error.
- **Worker crash**: supervisor marks worker failed; next send can auto-recreate worker.
- **Handshake mismatch**: app refuses attach and starts clean supervisor.
- **Protocol mismatch**: app asks for upgrade/restart path instead of best-effort behavior.

## Security/Safety

- Use per-instance random `instanceToken` and require it in `hello`.
- Restrict socket/endpoint permissions to current user.
- Validate `workingDirectory` exactly as current manager does.
- Never execute arbitrary shell from protocol without allowlisted commands.

## Test Plan

Unit tests:

1. stale supervisor record is reaped and replaced.
2. pid alive but token mismatch -> treated as stale.
3. reconnect attaches to existing valid supervisor.
4. worker auto-start on first ticket send.
5. `ticket.completed` event unblocks next ticket in loop manager.

Integration tests:

1. app restart while worker running -> reconnect and continue streaming.
2. supervisor restart mid-run -> app reattaches and resumes.
3. worker crash -> recreate and retry policy behaves as expected.

## Practical Recommendation

If you want fastest path now:

1. implement **Option B** first (app-launched supervisor + PID/token handshake),
2. keep worker ownership in supervisor,
3. migrate to **LaunchAgent** once loop behavior is stable.

This gives near-term robustness with a low rewrite cost and preserves your current project-scoped worker model.
