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

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

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

    const { events } = await thread.runStreamed(prompt, {
      signal: controller.signal,
    });

    for await (const event of events) {
      if (event.type === "thread.started") {
        currentThreadId = event.thread_id;
        threads.set(currentThreadId, thread);
        setActiveThread(requestId, currentThreadId);
      }

      if (
        event.type === "item.completed" &&
        event.item?.type === "agent_message"
      ) {
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
    const message = controller.signal.aborted
      ? "cancelled"
      : normalizeError(error);
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
