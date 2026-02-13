import crypto from "node:crypto";
import { once } from "node:events";
import readline from "node:readline";
import { Codex } from "@openai/codex-sdk";

const codex = new Codex();

// logical threadId (ticket ID) -> Codex thread ID
const threadAliases = new Map();

// requestId -> { controller: AbortController, mode: "plan" | "implement", logicalThreadId: string | null, codexThreadId: string | null }
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

function parseWorkingDirectory(msg) {
  if (msg.workingDirectory == null) {
    return null;
  }
  if (
    typeof msg.workingDirectory === "string" &&
    msg.workingDirectory.trim().length > 0
  ) {
    return msg.workingDirectory.trim();
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

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function markThreadAlias(logicalThreadId, codexThreadId) {
  if (
    isNonEmptyString(logicalThreadId) &&
    isNonEmptyString(codexThreadId) &&
    logicalThreadId !== codexThreadId
  ) {
    threadAliases.set(logicalThreadId, codexThreadId);
  }
}

function setActiveThreadBindings(
  requestId,
  { logicalThreadId = null, codexThreadId = null },
) {
  const active = activeRequests.get(requestId);
  if (!active) return;

  const previousThreadIds = [active.logicalThreadId, active.codexThreadId];
  for (const threadId of previousThreadIds) {
    if (isNonEmptyString(threadId) && activeByThread.get(threadId) === requestId) {
      activeByThread.delete(threadId);
    }
  }

  active.logicalThreadId = isNonEmptyString(logicalThreadId)
    ? logicalThreadId
    : null;
  active.codexThreadId = isNonEmptyString(codexThreadId) ? codexThreadId : null;

  const nextThreadIds = [active.logicalThreadId, active.codexThreadId];
  for (const threadId of nextThreadIds) {
    if (isNonEmptyString(threadId)) {
      activeByThread.set(threadId, requestId);
    }
  }
}

function clearActiveRequest(requestId) {
  const active = activeRequests.get(requestId);
  if (!active) return;

  const threadIds = [active.logicalThreadId, active.codexThreadId];
  for (const threadId of threadIds) {
    if (isNonEmptyString(threadId) && activeByThread.get(threadId) === requestId) {
      activeByThread.delete(threadId);
    }
  }

  activeRequests.delete(requestId);
}

function buildThreadOptions(mode, workingDirectory) {
  return {
    sandboxMode: mode === "implement" ? "workspace-write" : "read-only",
    approvalPolicy: "never",
    workingDirectory: workingDirectory ?? undefined,
  };
}

function isThreadBusy(requestedThreadId) {
  if (!requestedThreadId) {
    return false;
  }

  if (activeByThread.has(requestedThreadId)) {
    return true;
  }

  const aliasedThreadId = threadAliases.get(requestedThreadId);
  if (isNonEmptyString(aliasedThreadId) && activeByThread.has(aliasedThreadId)) {
    return true;
  }

  return false;
}

function resolveThreadForRequest(requestedThreadId, mode, workingDirectory) {
  const threadOptions = buildThreadOptions(mode, workingDirectory);

  if (requestedThreadId) {
    const aliasedThreadId = threadAliases.get(requestedThreadId);
    if (isNonEmptyString(aliasedThreadId)) {
      return {
        thread: codex.resumeThread(aliasedThreadId, threadOptions),
        logicalThreadId: requestedThreadId,
        codexThreadId: aliasedThreadId,
      };
    }

    return {
      thread: codex.startThread(threadOptions),
      logicalThreadId: requestedThreadId,
      codexThreadId: null,
    };
  }

  return {
    thread: codex.startThread(threadOptions),
    logicalThreadId: null,
    codexThreadId: null,
  };
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

  const workingDirectory = parseWorkingDirectory(msg);
  if (workingDirectory === "__invalid__") {
    await enqueueFrame({
      type: "ticket.completed",
      requestId,
      success: false,
      error: "invalid_working_directory",
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

  if (isThreadBusy(requestedThreadId)) {
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

  const {
    thread,
    logicalThreadId,
    codexThreadId: initialCodexThreadId,
  } = resolveThreadForRequest(requestedThreadId, mode, workingDirectory);
  const controller = new AbortController();

  activeRequests.set(requestId, {
    controller,
    mode,
    logicalThreadId: null,
    codexThreadId: null,
  });
  setActiveThreadBindings(requestId, {
    logicalThreadId,
    codexThreadId: initialCodexThreadId,
  });

  let currentThreadId =
    initialCodexThreadId ?? logicalThreadId ?? thread.id ?? null;
  markThreadAlias(logicalThreadId, currentThreadId);
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
        setActiveThreadBindings(requestId, {
          logicalThreadId,
          codexThreadId: currentThreadId,
        });
        markThreadAlias(logicalThreadId, currentThreadId);
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
    markThreadAlias(logicalThreadId, currentThreadId);
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
