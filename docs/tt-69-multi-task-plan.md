# TT-69 Plan: Concurrent Planning Tasks, Single Implementation Flight

## Summary

Enable multiple concurrent ticket tasks for a single project when they are in planning/chat mode, while keeping implementation mode single-flight.

Also align ticket status semantics so a ticket is only marked `In Progress` when the user explicitly clicks **Start Implementation**.

## Current Constraints (Verified)

1. Supervisor currently enforces a single in-flight request per project.
2. Worker session tracks one `activeRequestID`.
3. Sidecar currently processes stdin strictly serially (`await runStreamed` inside the line loop).
4. UI marks tickets `In Progress` on generic Send, including plan mode.

## Target Behavior

1. Multiple plan-mode requests can run concurrently for the same project.
2. At most one implementation-mode request can run at a time per project.
3. Per-ticket cancel cancels only that request, not the entire worker process.
4. Ticket status changes to `In Progress` only when implementation starts.

## Design Decisions

### 1. Sidecar protocol additions

Require these fields for submit payload:

- `type`: `"submitTask"`
- `requestId`: non-empty string
- `mode`: `"plan" | "implement"`
- `prompt`: string
- `threadId`: optional non-empty string

Require cancel payload:

- `{"type":"cancelTask","requestId":"..."}`

No backward-compatibility shims are included in this plan; invalid/missing fields are rejected.

### 2. Sidecar concurrency model

1. Dispatch each submit as its own async job (do not block stdin loop).
2. Track active requests by `requestId` with `AbortController`.
3. Track active request per `threadId` to avoid overlapping turns on the same thread.
4. Serialize stdout writes through a write queue so JSON lines are never interleaved.

### 3. Admission rules

1. Reject submit when `mode == implement` and another implement request is active.
2. Reject submit when requested `threadId` already has an in-flight request.
3. Allow unlimited concurrent `plan` requests across different threads.

### 4. Supervisor/app changes required for full TT-69

1. Include `mode` in sidecar submit payload.
2. Move per-project `activeRequestID` model to mode-aware active request tracking.
3. Route Stop/Cancel to `cancelTask` for per-ticket cancellation (instead of killing worker).
4. Remove generic-send `In Progress` transition; set it only in `startImplementation(...)`.

## Implementation Phases

### Phase 1: Sidecar

1. Replace single global thread state with maps:
   - `threads`
   - `activeRequests`
   - `activeByThread`
2. Add async job dispatch for submits.
3. Add request-scoped cancellation via `AbortController`.
4. Add mode-based implementation single-flight gate.
5. Add stdout write queue.

### Phase 2: Supervisor

1. Extend sidecar submit command schema with `mode`.
2. Track concurrent active requests per project, with admission rule:
   - many `plan`
   - max one `implement`
3. Implement per-request cancel passthrough to sidecar.
4. Keep task/event mapping stable for replay/resume.

### Phase 3: UI/Manager status semantics

1. Do not set ticket `In Progress` on generic Send.
2. Set `In Progress` in explicit Start Implementation flow only.
3. Ensure plan sends keep ticket in non-implementation status.

### Phase 4: Tests

1. Sidecar behavior tests (if sidecar repo has tests):
   - concurrent submit acceptance
   - thread busy rejection
   - implementation gate rejection
   - per-request cancellation
2. TicketParty unit tests:
   - status transition timing
   - mode-aware submit behavior
   - cancel behavior is per-ticket (no worker-wide stop)

## Validation

1. Build:
   - `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -configuration Debug build`
2. Unit tests:
   - `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test -only-testing:TicketPartyTests`
3. Manual runtime checks:
   - start two plan tasks in same project -> both run
   - start implement while implement active -> rejected
   - cancel one plan task -> other plan/implement tasks continue

## Final `sidecar.mjs` (drop-in)

Path: `/Users/kelan/dev/codex-sidecar/sidecar.mjs`

```js
import crypto from "node:crypto";
import { once } from "node:events";
import readline from "node:readline";
import { Codex } from "@openai/codex-sdk";

const codex = new Codex();

// threadId -> Thread
const threads = new Map();

// requestId -> { controller: AbortController, mode: "plan" | "implement", threadId: string | null }
const activeRequests = new Map();

// threadId -> requestId
const activeByThread = new Map();

const activeJobs = new Set();

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

let writeChain = Promise.resolve();

function enqueueFrame(frame) {
	const task = async () => {
		const line = JSON.stringify(frame) + "\n";
		if (!process.stdout.write(line)) {
			await once(process.stdout, "drain");
		}
	};

	writeChain = writeChain.then(task, task);
	return writeChain;
}

function normalizeError(error) {
	if (error instanceof Error) {
		return error.message;
	}
	return String(error);
}

function parseRequestId(msg) {
	if (typeof msg.requestId === "string" && msg.requestId.length > 0) {
		return msg.requestId;
	}
	return null;
}

function parseMode(msg) {
	if (msg.mode === "plan" || msg.mode === "implement") {
		return msg.mode;
	}
	return null;
}

function parseThreadId(msg) {
	if (msg.threadId == null) {
		return null;
	}
	if (typeof msg.threadId === "string" && msg.threadId.length > 0) {
		return msg.threadId;
	}
	return "__invalid__";
}

function hasImplementationInFlight() {
	for (const active of activeRequests.values()) {
		if (active.mode === "implement") {
			return true;
		}
	}
	return false;
}

function setActiveThread(requestId, nextThreadId) {
	const active = activeRequests.get(requestId);
	if (!active) return;

	if (active.threadId && activeByThread.get(active.threadId) === requestId) {
		activeByThread.delete(active.threadId);
	}

	if (typeof nextThreadId === "string" && nextThreadId.length > 0) {
		active.threadId = nextThreadId;
		activeByThread.set(nextThreadId, requestId);
	} else {
		active.threadId = null;
	}
}

function clearActiveRequest(requestId) {
	const active = activeRequests.get(requestId);
	if (!active) return;

	if (active.threadId && activeByThread.get(active.threadId) === requestId) {
		activeByThread.delete(active.threadId);
	}

	activeRequests.delete(requestId);
}

function resolveThread(threadId) {
	if (threadId) {
		const existing = threads.get(threadId);
		if (existing) return existing;

		const resumed = codex.resumeThread(threadId);
		threads.set(threadId, resumed);
		return resumed;
	}

	return codex.startThread();
}

async function handleSubmit(msg) {
	const requestId = parseRequestId(msg);
	if (!requestId) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId: crypto.randomUUID(),
			success: false,
			error: "missing_request_id",
		});
		return;
	}

	const prompt = msg.prompt;

	if (typeof prompt !== "string") {
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			success: false,
			error: "missing_prompt",
		});
		return;
	}

	const mode = parseMode(msg);
	if (!mode) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			success: false,
			error: "invalid_mode",
		});
		return;
	}

	if (activeRequests.has(requestId)) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			success: false,
			error: "request_already_active",
			summary: `Request ${requestId} is already in flight.`,
		});
		return;
	}

	if (mode === "implement" && hasImplementationInFlight()) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			success: false,
			error: "implementation_in_flight",
			summary: "Another implementation request is already running.",
		});
		return;
	}

	const requestedThreadId = parseThreadId(msg);
	if (requestedThreadId === "__invalid__") {
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			success: false,
			error: "invalid_thread_id",
		});
		return;
	}

	if (requestedThreadId && activeByThread.has(requestedThreadId)) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			threadId: requestedThreadId,
			success: false,
			error: "thread_busy",
			summary: `Thread ${requestedThreadId} already has an in-flight request.`,
		});
		return;
	}

	const thread = resolveThread(requestedThreadId);
	const controller = new AbortController();

	activeRequests.set(requestId, { controller, mode, threadId: null });
	setActiveThread(requestId, requestedThreadId);

	let currentThreadId = requestedThreadId ?? thread.id ?? null;
	let finalResponse = "";
	let usage = null;
	let failureMessage = null;

	try {
		await enqueueFrame({
			type: "ticket.started",
			requestId,
			threadId: currentThreadId ?? undefined,
		});

		const { events } = await thread.runStreamed(prompt, { signal: controller.signal });

		for await (const event of events) {
			if (event.type === "thread.started") {
				currentThreadId = event.thread_id;
				threads.set(currentThreadId, thread);
				setActiveThread(requestId, currentThreadId);
			}

			if (event.type === "item.completed" && event.item?.type === "agent_message") {
				finalResponse = event.item.text ?? finalResponse;
				await enqueueFrame({
					type: "ticket.output",
					requestId,
					threadId: currentThreadId ?? undefined,
					text: event.item.text ?? "",
				});
			}

			if (event.type === "turn.completed") {
				usage = event.usage ?? null;
			} else if (event.type === "turn.failed") {
				failureMessage = event.error?.message ?? "turn.failed";
			}

			await enqueueFrame({
				type: "codex.event",
				requestId,
				threadId: currentThreadId ?? undefined,
				event,
			});
		}

		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			threadId: currentThreadId ?? undefined,
			success: failureMessage == null,
			summary: failureMessage ?? finalResponse,
			finalResponse,
			usage,
			error: failureMessage,
		});
	} catch (error) {
		const message = controller.signal.aborted ? "cancelled" : normalizeError(error);
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			threadId: currentThreadId ?? undefined,
			success: false,
			summary: message,
			finalResponse,
			usage,
			error: message,
		});
	} finally {
		clearActiveRequest(requestId);
	}
}

async function handleCancel(msg) {
	const requestId = parseRequestId(msg);
	if (!requestId) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId: crypto.randomUUID(),
			success: false,
			error: "missing_request_id",
		});
		return;
	}

	const active = activeRequests.get(requestId);
	if (!active) {
		return;
	}

	active.controller.abort();
}

function dispatchMessage(msg) {
	if (msg.type === "submitTask") {
		return handleSubmit(msg);
	}
	if (msg.type === "cancelTask") {
		return handleCancel(msg);
	}

	const requestId = parseRequestId(msg) ?? crypto.randomUUID();
	return enqueueFrame({
		type: "ticket.completed",
		requestId,
		success: false,
		error: "invalid_message_type",
	});
}

for await (const line of rl) {
	if (!line.trim()) {
		continue;
	}

	let msg;
	try {
		msg = JSON.parse(line);
	} catch {
		await enqueueFrame({
			type: "ticket.completed",
			requestId: crypto.randomUUID(),
			success: false,
			error: "invalid_json",
		});
		continue;
	}

	if (msg == null || typeof msg !== "object" || Array.isArray(msg)) {
		await enqueueFrame({
			type: "ticket.completed",
			requestId: crypto.randomUUID(),
			success: false,
			error: "invalid_message_shape",
		});
		continue;
	}

	const job = dispatchMessage(msg).catch(async (error) => {
		const requestId = parseRequestId(msg) ?? crypto.randomUUID();
		await enqueueFrame({
			type: "ticket.completed",
			requestId,
			success: false,
			error: normalizeError(error),
		});
	});

	activeJobs.add(job);
	void job.finally(() => {
		activeJobs.delete(job);
	});
}

await Promise.allSettled(Array.from(activeJobs));
await writeChain;
```

## Open Questions

1. Should sidecar enforce global max concurrent plan tasks (for CPU/memory control), or leave that to supervisor?
2. Should cancellation emit an explicit `ticket.cancelled` event in addition to `ticket.completed(success=false)`?
3. Should implement-mode gating be enforced in both sidecar and supervisor (recommended), or supervisor only?
