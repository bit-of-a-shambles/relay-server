import { describe, expect, it } from "vitest";
import { createInferenceJobSink, executeAsyncResponse, responseEvents, type InferenceJob } from "../src/async-inference.js";

const completed = { id: "response-1", status: "completed", model: "coder", output: [
  { id: "m", type: "message", role: "assistant", content: [{ type: "output_text", text: "Done" }, { type: "refusal", refusal: "No" }] },
  { id: "t", type: "function_call", call_id: "c", name: "read_file", arguments: '{"path":"x"}' },
  { id: "r", type: "reasoning", summary: [] }
] };

function args(fetchImpl: typeof fetch) {
  return { body: { model: "coder" }, baseUrl: "https://doubleword.invalid/v1", headers: {}, sessionId: "session", runId: "run", signal: new AbortController().signal, fetchImpl, onJob: undefined };
}

describe("Doubleword background inference", () => {
  it("polls queued/in-progress jobs with bounded backoff and persists statuses before delivering tool calls", async () => {
    const updates: InferenceJob[] = [], waits: number[] = [], requests: RequestInit[] = [];
    const replies = [{ id: "response-1", status: "queued" }, { id: "response-1", status: "in_progress" }, { id: "response-1", status: "queued" }, { id: "response-1", status: "queued" }, completed];
    const fetchImpl: typeof fetch = async (_url, init) => { requests.push(init!); return Response.json(replies.shift()); };
    const result = await executeAsyncResponse({ ...args(fetchImpl), body: { model: "coder", stream: true }, onJob: async (job) => { updates.push(job); }, sleep: async (ms) => { waits.push(ms); } });
    expect(JSON.parse(requests[0]!.body as string)).toMatchObject({ background: true, service_tier: "flex", stream: false });
    expect(waits).toEqual([2000, 4000, 8000, 10000]);
    expect(updates.map((job) => job.status)).toEqual(["queued", "in_progress", "queued", "queued", "completed"]);
    const stream = await result.text();
    expect(stream).toContain("response.function_call_arguments.delta");
    expect(stream).toContain("response.completed");
    expect(stream).toContain('"sequence_number":0');
    expect(responseEvents({ id: "empty", status: "completed" })).toContain("response.completed");
  });

  it("returns direct completions and upstream errors without resubmitting requests", async () => {
    expect(await (await executeAsyncResponse(args(async () => Response.json(completed)))).json()).toEqual(completed);
    expect((await executeAsyncResponse(args(async () => new Response("quota", { status: 429 })))).status).toBe(429);
    await expect(executeAsyncResponse(args(async () => Response.json({ status: "queued" })))).rejects.toThrow("response ID");
    await expect(executeAsyncResponse(args(async () => Response.json({ id: "", status: "queued" })))).rejects.toThrow("response ID");
  });

  it("fails timed-out, failed and unreadable jobs without replaying a tool", async () => {
    for (const failure of ["timeout", "poll", "failed"]) {
      const updates: InferenceJob[] = [];
      let calls = 0;
      const fetchImpl: typeof fetch = async (_url) => {
        calls++;
        if (String(_url).endsWith("/cancel")) throw new Error("cancel unsupported");
        if (calls === 1) return Response.json({ id: "response-1", status: failure === "failed" ? "failed" : "queued" });
        return new Response("offline", { status: 503 });
      };
      await expect(executeAsyncResponse({ ...args(fetchImpl), onJob: async (job) => { updates.push(job); }, clock: () => 1, timeoutMs: failure === "timeout" ? 0 : 10, sleep: async () => {} })).rejects.toThrow();
      expect(updates.at(-1)!.status).toBe("failed");
    }
  });

  it("cancels a blocked waiter and attempts upstream cancellation", async () => {
    const controller = new AbortController(), updates: InferenceJob[] = [], urls: string[] = [];
    controller.abort();
    const fetchImpl: typeof fetch = async (url) => { urls.push(String(url)); return Response.json({ id: "response-1", status: "queued" }); };
    await expect(executeAsyncResponse({ ...args(fetchImpl), signal: controller.signal, onJob: async (job) => { updates.push(job); } })).rejects.toThrow();
    expect(updates.at(-1)!.status).toBe("cancelled");
    expect(urls.at(-1)).toContain("/response-1/cancel");
  });

  it("creates an authenticated persistence sink and reports durable-store failures", async () => {
    expect(createInferenceJobSink(undefined, "token")).toBeUndefined();
    expect(createInferenceJobSink("http://daemon", undefined)).toBeUndefined();
    let request: RequestInit | undefined;
    const sink = createInferenceJobSink("http://daemon", "token", async (_url, init) => { request = init; return new Response("{}"); })!;
    const job = { responseId: "id", sessionId: "session", runId: "run", status: "queued" };
    await sink(job);
    expect(request!.headers).toMatchObject({ Authorization: "Bearer token" });
    expect(JSON.parse(request!.body as string)).toEqual(job);
    await expect(createInferenceJobSink("http://daemon", "token", async () => new Response("", { status: 503 }))!(job)).rejects.toThrow("persist");
  });
});
