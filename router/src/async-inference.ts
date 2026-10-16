import { setTimeout as delay } from "node:timers/promises";
import { sse } from "./sse.js";

export type InferenceJob = { responseId: string; sessionId: string; runId: string; status: string };
export type InferenceJobSink = (job: InferenceJob) => Promise<void>;

export function createInferenceJobSink(url: string | undefined, token: string | undefined,
  fetchImpl: typeof fetch = fetch): InferenceJobSink | undefined {
  if (!url || !token) return undefined;
  return async (job) => {
    const result = await fetchImpl(url, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(job), signal: AbortSignal.timeout(5000) });
    if (!result.ok) throw new Error("Could not persist inference job on the Mac");
  };
}

type NativeResponse = { id: string; status: string; model?: string; output?: Record<string, unknown>[]; [key: string]: unknown };

// Async is a capability of the Responses path. Tool calls are delivered only
// after completion; a cancelled/interrupted waiter never resumes agent tools.
export async function executeAsyncResponse(args: {
  body: Record<string, unknown>; baseUrl: string; headers: Record<string, string>;
  sessionId: string; runId: string; signal: AbortSignal; fetchImpl: typeof fetch;
  onJob: InferenceJobSink | undefined; timeoutMs?: number; clock?: () => number;
  sleep?: (ms: number, signal: AbortSignal) => Promise<unknown>;
}): Promise<Response> {
  const clock = args.clock ?? Date.now;
  const sleep = args.sleep ?? ((ms, signal) => delay(ms, undefined, { signal }));
  const deadline = clock() + (args.timeoutMs ?? 3_600_000);
  let id = "";
  const notify = async (status: string): Promise<void> => {
    await args.onJob?.({ responseId: id, sessionId: args.sessionId, runId: args.runId, status });
  };
  try {
    const created = await args.fetchImpl(`${args.baseUrl}/responses`, { method: "POST", headers: args.headers,
      body: JSON.stringify({ ...args.body, stream: false, background: true, service_tier: "flex" }), signal: args.signal });
    if (!created.ok) return created;
    let result = await created.json() as NativeResponse;
    if (typeof result.id !== "string" || !result.id) throw new Error("Async inference returned no response ID");
    id = result.id;
    let attempt = 0;
    while (result.status === "queued" || result.status === "in_progress") {
      await notify(result.status);
      if (clock() >= deadline) throw new Error("Async inference exceeded its 60-minute deadline");
      await sleep(Math.min(2000 * 2 ** attempt, 10000), args.signal);
      args.signal.throwIfAborted();
      const polled = await args.fetchImpl(`${args.baseUrl}/responses/${encodeURIComponent(id)}`, { headers: args.headers, signal: args.signal });
      if (!polled.ok) throw new Error("Could not retrieve async inference result");
      result = await polled.json() as NativeResponse;
      attempt += 1;
    }
    if (result.status !== "completed") throw new Error("Async inference did not complete successfully");
    await notify("completed");
    if (args.body.stream !== true) return Response.json(result);
    return new Response(responseEvents(result), { headers: { "Content-Type": "text/event-stream" } });
  } catch (error) {
    if (id) {
      await notify(args.signal.aborted ? "cancelled" : "failed");
      // Cancellation may be unsupported upstream; local cancellation still stops
      // waiting and tool execution, without claiming an upstream billing refund.
      await args.fetchImpl(`${args.baseUrl}/responses/${encodeURIComponent(id)}/cancel`, { method: "POST", headers: args.headers }).catch(() => undefined);
    }
    throw error;
  }
}

export function responseEvents(result: NativeResponse): string {
  let sequence = 0;
  const event = (type: string, data: Record<string, unknown>): string => sse(type, { type, sequence_number: sequence++, ...data });
  let events = event("response.created", { response: { ...result, status: "in_progress", output: [] } });
  for (const [index, item] of (result.output ?? []).entries()) {
    const shared = { output_index: index, item_id: item.id };
    const start = { ...item };
    if (item.type === "message") start.content = [];
    if (item.type === "function_call") start.arguments = "";
    events += event("response.output_item.added", { ...shared, item: start });
    if (item.type === "message") {
      for (const [contentIndex, part] of (item.content as Record<string, unknown>[]).entries()) {
        const metadata = { ...shared, content_index: contentIndex };
        events += event("response.content_part.added", { ...metadata, part: { ...part, text: "" } });
        if (part.type === "output_text") {
          events += event("response.output_text.delta", { ...metadata, delta: part.text });
          events += event("response.output_text.done", { ...metadata, text: part.text });
        }
        events += event("response.content_part.done", { ...metadata, part });
      }
    } else if (item.type === "function_call") {
      events += event("response.function_call_arguments.delta", { ...shared, delta: item.arguments });
      events += event("response.function_call_arguments.done", { ...shared, arguments: item.arguments });
    }
    events += event("response.output_item.done", { ...shared, item });
  }
  return events + event("response.completed", { response: result });
}
