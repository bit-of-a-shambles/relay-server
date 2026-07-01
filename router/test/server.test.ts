import { afterEach, describe, expect, it } from "vitest";
import { createConnection } from "node:net";
import {
  createRelayRouterServer,
  defaultOptionsFromEnv,
  type RouterServerOptions
} from "../src/server.js";
import { DEFAULT_ROUTING_CONFIG } from "../src/routing.js";
import { MemoryCallLogSink } from "../src/call-log.js";
import { createTestServer, type TestHttpServer } from "./helpers.js";

const openServers: TestHttpServer[] = [];

afterEach(async () => {
  await Promise.all(openServers.splice(0).map((server) => server.close()));
});

describe("Relay router HTTP server", () => {
  it("proxies non-streaming Anthropic messages to OpenRouter chat completions", async () => {
    const upstream = await createTestServer((request, response) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify({
          id: "chatcmpl_test",
          model: "openrouter/test",
          choices: [
            {
              index: 0,
              finish_reason: "stop",
              message: {
                role: "assistant",
                content: "Done"
              }
            }
          ],
          usage: {
            prompt_tokens: 11,
            completion_tokens: 2,
            total_tokens: 13
          }
        })
      );
    });
    openServers.push(upstream);

    const router = await listenRouter(upstream.baseUrl);
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer dummy"
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      type: "message",
      role: "assistant",
      content: [{ type: "text", text: "Done" }],
      stop_reason: "end_turn",
      usage: {
        input_tokens: 11,
        output_tokens: 2
      }
    });

    expect(upstream.requests).toHaveLength(1);
    expect(upstream.requests[0]?.url).toBe("/chat/completions");
    expect(upstream.requests[0]?.headers.authorization).toBe("Bearer test-key");
    expect(upstream.requests[0]?.headers["http-referer"]).toBe("relay.local");
    expect(upstream.requests[0]?.headers["x-openrouter-title"]).toBe("Relay");

    const upstreamBody = JSON.parse(upstream.requests[0]?.body ?? "{}") as Record<string, unknown>;
    expect(upstreamBody).toMatchObject({
      model: "moonshotai/kimi-k2",
      max_tokens: 100,
      messages: [{ role: "user", content: "Say done" }],
      stream: false
    });
  });

  it("stamps task and session ids from scoped message routes onto call records", async () => {
    const sink = new MemoryCallLogSink();
    const upstream = await createTestServer((request, response) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify({
          id: "chatcmpl_task",
          model: "openrouter/test",
          choices: [
            { index: 0, finish_reason: "stop", message: { role: "assistant", content: "ok" } }
          ],
          usage: { prompt_tokens: 5, completion_tokens: 1, total_tokens: 6 }
        })
      );
    });
    openServers.push(upstream);

    const router = await listenRouterWithOptions({
      openRouterBaseUrl: upstream.baseUrl,
      callLogSink: sink
    });
    openServers.push(router);

    const taskResponse = await fetch(`${router.baseUrl}/api/task/task-abc-123/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 50,
        messages: [{ role: "user", content: "hi" }]
      })
    });
    const sessionResponse = await fetch(`${router.baseUrl}/api/session/session-xyz-789/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 50,
        messages: [{ role: "user", content: "hi again" }]
      })
    });

    expect(taskResponse.status).toBe(404);
    expect(sessionResponse.status).toBe(200);
    expect(sink.records).toHaveLength(1);
    expect(sink.records[0]?.sessionId).toBe("session-xyz-789");
  });

  it("routes by config, retries non-streaming upstream errors, and records call logs", async () => {
    const sink = new MemoryCallLogSink();
    let attempt = 0;
    const upstream = await createTestServer((request, response) => {
      attempt += 1;
      if (attempt === 1) {
        response.writeHead(500, { "Content-Type": "text/plain" });
        response.end("broken model");
        return;
      }

      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify({
          id: "chatcmpl_retry",
          model: "anthropic/claude-sonnet-latest",
          choices: [
            {
              index: 0,
              finish_reason: "stop",
              message: { role: "assistant", content: "Recovered" }
            }
          ],
          usage: {
            prompt_tokens: 20,
            completion_tokens: 3,
            total_tokens: 23,
            cost: 0.0001
          }
        })
      );
    });
    openServers.push(upstream);

    const router = await listenRouterWithOptions({
      openRouterBaseUrl: upstream.baseUrl,
      callLogSink: sink
    });
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        metadata: { qualityDial: 8 },
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      content: [{ type: "text", text: "Recovered" }]
    });

    expect(upstream.requests.map((request) => JSON.parse(request.body).model)).toEqual([
      "anthropic/claude-sonnet-latest",
      "anthropic/claude-opus-latest"
    ]);
    expect(sink.records).toHaveLength(2);
    expect(sink.records[0]).toMatchObject({
      sessionId: null,
      requestedModel: "claude-sonnet-4-5",
      routedModel: "anthropic/claude-sonnet-latest",
      tier: 2,
      escalationReason: null,
      status: "error",
      errorMessage: "broken model"
    });
    expect(sink.records[1]).toMatchObject({
      requestedModel: "claude-sonnet-4-5",
      routedModel: "anthropic/claude-opus-latest",
      tier: 3,
      escalationReason: "upstream_error_retry",
      status: "success",
      costUsd: 0.0001,
      completionTokens: 3
    });
    expect(sink.records[1]?.frontierCostUsd).toBeGreaterThan(0);
  });

  it("returns the final non-streaming error after retry exhaustion", async () => {
    const sink = new MemoryCallLogSink();
    const upstream = await createTestServer((request, response) => {
      response.writeHead(503, { "Content-Type": "text/plain" });
      response.end(`failure ${upstream.requests.length}`);
    });
    openServers.push(upstream);

    const router = await listenRouterWithOptions({
      openRouterBaseUrl: upstream.baseUrl,
      callLogSink: sink
    });
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      error: { message: "failure 2" }
    });
    expect(sink.records).toHaveLength(2);
    expect(sink.records.every((record) => record.status === "error")).toBe(true);
  });

  it("does not retry duplicate routes and records missing cost as null", async () => {
    const sink = new MemoryCallLogSink();
    const upstream = await createTestServer((request, response) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify({
          id: "chatcmpl_no_cost",
          model: "anthropic/claude-opus-latest",
          choices: [
            {
              index: 0,
              finish_reason: "stop",
              message: { role: "assistant", content: "Top tier" }
            }
          ],
          usage: []
        })
      );
    });
    openServers.push(upstream);

    const router = await listenRouterWithOptions({
      openRouterBaseUrl: upstream.baseUrl,
      callLogSink: sink
    });
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        metadata: { qualityDial: 10 },
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(response.status).toBe(200);
    expect(upstream.requests).toHaveLength(1);
    expect(sink.records).toHaveLength(1);
    expect(sink.records[0]).toMatchObject({
      routedModel: "anthropic/claude-opus-latest",
      costUsd: null,
      completionTokens: 0
    });
  });

  it("proxies streaming responses as Anthropic SSE", async () => {
    const upstream = await createTestServer((request, response) => {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(
        'data: {"id":"chatcmpl_stream","model":"openrouter/test","choices":[{"index":0,"delta":{"role":"assistant"}}]}\n\n'
      );
      response.write(
        'data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}\n\n'
      );
      response.write(
        'data: {"choices":[{"index":0,"finish_reason":"stop","delta":{}}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}\n\n'
      );
      response.end("data: [DONE]\n\n");
    });
    openServers.push(upstream);

    const router = await listenRouter(upstream.baseUrl);
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer dummy"
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        stream: true,
        messages: [{ role: "user", content: "Say hi" }]
      })
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const text = await response.text();
    expect(text).toContain("event: message_start");
    expect(text).toContain('"type":"text_delta","text":"Hi"');
    expect(text).toContain('"stop_reason":"end_turn"');
    expect(text).toContain("event: message_stop");

    const upstreamBody = JSON.parse(upstream.requests[0]?.body ?? "{}") as Record<string, unknown>;
    expect(upstreamBody).toMatchObject({
      stream: true,
      stream_options: { include_usage: true }
    });
  });

  it("records streaming upstream successes and failures", async () => {
    const successSink = new MemoryCallLogSink();
    const upstream = await createTestServer((request, response) => {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end("data: [DONE]\n\n");
    });
    openServers.push(upstream);

    const router = await listenRouterWithOptions({
      openRouterBaseUrl: upstream.baseUrl,
      callLogSink: successSink
    });
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        stream: true,
        messages: [{ role: "user", content: "Say hi" }]
      })
    });
    expect(response.status).toBe(200);
    expect(successSink.records).toHaveLength(1);
    expect(successSink.records[0]).toMatchObject({
      status: "success",
      routedModel: "moonshotai/kimi-k2"
    });

    const failureSink = new MemoryCallLogSink();
    const failureRouter = await listenRouterWithOptions({
      callLogSink: failureSink,
      fetchImpl: async () => new Response("stream failed", { status: 500 })
    });
    openServers.push(failureRouter);

    const failureResponse = await fetch(`${failureRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        stream: true,
        messages: [{ role: "user", content: "Say hi" }]
      })
    });
    expect(failureResponse.status).toBe(500);
    expect(failureSink.records).toHaveLength(1);
    expect(failureSink.records[0]).toMatchObject({
      status: "error",
      errorMessage: "stream failed"
    });
  });

  it("returns health, route, auth, and request validation errors", async () => {
    const routerWithoutKey = await listenRouterWithOptions({
      openRouterApiKey: undefined
    });
    openServers.push(routerWithoutKey);

    await expect(fetch(`${routerWithoutKey.baseUrl}/health`).then((response) => response.json()))
      .resolves.toEqual({ ok: true });

    const notFound = await fetch(`${routerWithoutKey.baseUrl}/missing`);
    expect(notFound.status).toBe(404);
    await expect(notFound.json()).resolves.toMatchObject({
      error: { type: "not_found_error" }
    });

    const postNotFound = await fetch(`${routerWithoutKey.baseUrl}/api/wrong`, {
      method: "POST"
    });
    expect(postNotFound.status).toBe(404);

    const missingKey = await fetch(`${routerWithoutKey.baseUrl}/api/v1/messages`, {
      method: "POST",
      body: "{}"
    });
    expect(missingKey.status).toBe(500);
    await expect(missingKey.json()).resolves.toMatchObject({
      error: { type: "authentication_error" }
    });

    const router = await listenRouterWithOptions();
    openServers.push(router);

    const invalidJson = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      body: "{"
    });
    expect(invalidJson.status).toBe(500);
    await expect(invalidJson.json()).resolves.toMatchObject({
      error: { type: "api_error" }
    });

    const invalidShape = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: "claude", max_tokens: 10 })
    });
    expect(invalidShape.status).toBe(500);
    await expect(invalidShape.json()).resolves.toMatchObject({
      error: { message: "Invalid Anthropic Messages request" }
    });

    const nullShape = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "null"
    });
    expect(nullShape.status).toBe(500);
    await expect(nullShape.json()).resolves.toMatchObject({
      error: { message: "Invalid Anthropic Messages request" }
    });
  });

  it("handles upstream error bodies and status text fallbacks", async () => {
    const upstream = await createTestServer((request, response) => {
      response.writeHead(429, { "Content-Type": "text/plain" });
      response.end("rate limited");
    });
    openServers.push(upstream);

    const router = await listenRouter(`${upstream.baseUrl}///`);
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toMatchObject({
      error: { message: "rate limited" }
    });
    expect(upstream.requests[0]?.url).toBe("/chat/completions");

    const statusTextRouter = await listenRouterWithOptions({
      fetchImpl: async () => new Response(null, { status: 503, statusText: "Unavailable" })
    });
    openServers.push(statusTextRouter);

    const statusTextResponse = await fetch(`${statusTextRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(statusTextResponse.status).toBe(503);
    await expect(statusTextResponse.json()).resolves.toMatchObject({
      error: { message: "Unavailable" }
    });

    const emptyBodyRouter = await listenRouterWithOptions({
      fetchImpl: async () => new Response("", { status: 502, statusText: "Bad Gateway" })
    });
    openServers.push(emptyBodyRouter);

    const emptyBodyResponse = await fetch(`${emptyBodyRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });

    expect(emptyBodyResponse.status).toBe(502);
    await expect(emptyBodyResponse.json()).resolves.toMatchObject({
      error: { message: "Bad Gateway" }
    });
  });

  it("handles empty streams, invalid upstream JSON, and thrown non-error values", async () => {
    const emptyStreamRouter = await listenRouterWithOptions({
      fetchImpl: async () => new Response(null, { status: 200 })
    });
    openServers.push(emptyStreamRouter);

    const emptyStreamResponse = await fetch(`${emptyStreamRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        stream: true,
        messages: [{ role: "user", content: "Say hi" }]
      })
    });
    expect(emptyStreamResponse.status).toBe(502);
    await expect(emptyStreamResponse.json()).resolves.toMatchObject({
      error: { message: "OpenRouter returned an empty stream" }
    });

    const invalidJsonRouter = await listenRouterWithOptions({
      fetchImpl: async () => Response.json(null)
    });
    openServers.push(invalidJsonRouter);

    const invalidJsonResponse = await fetch(`${invalidJsonRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });
    expect(invalidJsonResponse.status).toBe(502);
    await expect(invalidJsonResponse.json()).resolves.toMatchObject({
      error: { message: "Invalid OpenRouter response" }
    });

    const invalidShapeRouter = await listenRouterWithOptions({
      fetchImpl: async () => Response.json({})
    });
    openServers.push(invalidShapeRouter);

    const invalidShapeResponse = await fetch(`${invalidShapeRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });
    expect(invalidShapeResponse.status).toBe(502);
    await expect(invalidShapeResponse.json()).resolves.toMatchObject({
      error: { message: "Invalid OpenRouter response" }
    });

    const throwingRouter = await listenRouterWithOptions({
      fetchImpl: async () => {
        throw "not an Error";
      }
    });
    openServers.push(throwingRouter);

    const throwingResponse = await fetch(`${throwingRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });
    expect(throwingResponse.status).toBe(500);
    await expect(throwingResponse.json()).resolves.toMatchObject({
      error: { message: "Unexpected router error" }
    });

    const nonErrorJsonRouter = await listenRouterWithOptions({
      fetchImpl: async () =>
        ({
          ok: true,
          json: async () => {
            throw "bad json";
          }
        }) as Response
    });
    openServers.push(nonErrorJsonRouter);

    const nonErrorJsonResponse = await fetch(`${nonErrorJsonRouter.baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 100,
        messages: [{ role: "user", content: "Say done" }]
      })
    });
    expect(nonErrorJsonResponse.status).toBe(502);
    await expect(nonErrorJsonResponse.json()).resolves.toMatchObject({
      error: { message: "Invalid OpenRouter response" }
    });
  });

  it("rejects request bodies above the configured limit", async () => {
    const router = await listenRouterWithOptions();
    openServers.push(router);

    const response = await fetch(`${router.baseUrl}/api/v1/messages`, {
      method: "POST",
      body: "x".repeat(20 * 1024 * 1024 + 1)
    });

    expect(response.status).toBe(500);
    await expect(response.json()).resolves.toMatchObject({
      error: { message: "Request body too large" }
    });
  });

  it("handles aborted request streams", async () => {
    const router = await listenRouterWithOptions();
    openServers.push(router);

    const url = new URL(router.baseUrl);
    await new Promise<void>((resolve) => {
      const socket = createConnection(Number(url.port), url.hostname, () => {
        socket.write(
          [
            "POST /api/v1/messages HTTP/1.1",
            `Host: ${url.host}`,
            "Content-Type: application/json",
            "Content-Length: 100",
            "",
            "{\"model\""
          ].join("\r\n")
        );
        socket.destroy();
        setTimeout(resolve, 25);
      });
      socket.on("error", () => {
        resolve();
      });
    });
  });

  it("reads defaults and overrides from the environment", () => {
    const originalEnv = { ...process.env };

    try {
      delete process.env.RELAY_ROUTER_HOST;
      delete process.env.RELAY_ROUTER_PORT;
      delete process.env.OPENROUTER_API_KEY;
      delete process.env.OPENROUTER_BASE_URL;
      delete process.env.OPENROUTER_MODEL;
      delete process.env.OPENROUTER_HTTP_REFERER;
      delete process.env.OPENROUTER_APP_TITLE;

      expect(defaultOptionsFromEnv()).toMatchObject({
        host: "127.0.0.1",
        port: 7778,
      openRouterApiKey: undefined,
      openRouterBaseUrl: "https://openrouter.ai/api/v1",
      openRouterModel: "moonshotai/kimi-k2",
      routingConfigLoader: expect.any(Object),
      callLogSink: undefined,
      referer: "relay.local",
      title: "Relay"
      });

      process.env.RELAY_ROUTER_HOST = "0.0.0.0";
      process.env.RELAY_ROUTER_PORT = "9999";
      process.env.OPENROUTER_API_KEY = "key";
      process.env.OPENROUTER_BASE_URL = "https://example.test/api";
      process.env.OPENROUTER_MODEL = "example/model";
      process.env.OPENROUTER_HTTP_REFERER = "https://relay.test";
      process.env.OPENROUTER_APP_TITLE = "Relay Test";

      expect(defaultOptionsFromEnv()).toMatchObject({
        host: "0.0.0.0",
        port: 9999,
      openRouterApiKey: "key",
      openRouterBaseUrl: "https://example.test/api",
      openRouterModel: "example/model",
      routingConfigLoader: expect.any(Object),
      callLogSink: undefined,
      referer: "https://relay.test",
      title: "Relay Test"
      });
    } finally {
      process.env = originalEnv;
    }
  });
});

async function listenRouter(upstreamBaseUrl: string): Promise<TestHttpServer> {
  return listenRouterWithOptions({ openRouterBaseUrl: upstreamBaseUrl });
}

async function listenRouterWithOptions(
  options: Partial<RouterServerOptions> = {}
): Promise<TestHttpServer> {
  const server = createRelayRouterServer({
    host: "127.0.0.1",
    port: 0,
    openRouterApiKey: "test-key",
    openRouterBaseUrl: "http://127.0.0.1:9",
    openRouterModel: "openrouter/test-model",
    maxCompletionTokens: 4096,
    routingConfigLoader: { load: () => DEFAULT_ROUTING_CONFIG },
    referer: "relay.local",
    title: "Relay",
    ...options
  });

  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("Expected TCP router address");
  }

  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    requests: [],
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error !== undefined) {
            reject(error);
            return;
          }

          resolve();
        });
      })
  };
}
