import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { URL } from "node:url";
import { createInferenceJobSink, executeAsyncResponse, type InferenceJobSink } from "./async-inference.js";
import { fromOpenAIResponse, toOpenAIRequest } from "./translate.js";
import type {
  AnthropicMessagesRequest,
  OpenAIChatCompletionResponse
} from "./types.js";
import { collectText, openAIStreamToAnthropicSse, parseSse } from "./sse.js";
import {
  chooseRoute,
  createRoutingConfigLoader,
  estimateFrontierCostUsd,
  resolveUpstream,
  type ResolvedUpstream,
  type RoutingConfigLoader,
  type RoutingDecision
} from "./routing.js";
import {
  createCallLogSink,
  type CallLogSink,
  type LlmCallRecord
} from "./call-log.js";

export type RouterServerOptions = {
  host: string;
  port: number;
  openRouterApiKey: string | undefined;
  openRouterBaseUrl: string;
  openRouterModel: string;
  maxCompletionTokens: number;
  routingConfigLoader: RoutingConfigLoader;
  callLogSink: CallLogSink | undefined;
  referer: string;
  title: string;
  fetchImpl?: typeof fetch;
  inferenceJobSink?: InferenceJobSink | undefined;
};

const DEFAULT_MAX_BODY_BYTES = 20 * 1024 * 1024;

export function createRelayRouterServer(options: RouterServerOptions): Server {
  const fetchImpl = options.fetchImpl ?? fetch;

  return createServer(async (request, response) => {
    try {
      await handleRequest(request, response, options, fetchImpl);
    } catch (error: unknown) {
      sendJson(response, 500, {
        type: "error",
        error: {
          type: "api_error",
          message: error instanceof Error ? error.message : "Unexpected router error"
        }
      });
    }
  });
}

export function defaultOptionsFromEnv(): RouterServerOptions {
  return {
    inferenceJobSink: createInferenceJobSink(process.env.RELAY_LLM_CALL_SINK_URL?.replace("/llm-calls", "/inference-jobs"), process.env.RELAY_LLM_CALL_SINK_TOKEN),
    host: process.env.RELAY_ROUTER_HOST ?? "127.0.0.1",
    port: Number.parseInt(process.env.RELAY_ROUTER_PORT ?? "7778", 10),
    openRouterApiKey: process.env.OPENROUTER_API_KEY,
    openRouterBaseUrl: process.env.OPENROUTER_BASE_URL ?? "https://openrouter.ai/api/v1",
    openRouterModel: process.env.OPENROUTER_MODEL ?? "openai/gpt-5.5",
    maxCompletionTokens: Number.parseInt(process.env.RELAY_MAX_COMPLETION_TOKENS ?? "4096", 10),
    routingConfigLoader: createRoutingConfigLoader(process.env.RELAY_ROUTING_CONFIG),
    callLogSink: createCallLogSink({
      jsonlPath: process.env.RELAY_LLM_CALL_LOG,
      httpUrl: process.env.RELAY_LLM_CALL_SINK_URL,
      httpToken: process.env.RELAY_LLM_CALL_SINK_TOKEN
    }),
    referer: process.env.OPENROUTER_HTTP_REFERER ?? "relay.local",
    title: process.env.OPENROUTER_APP_TITLE ?? "Relay"
  };
}

async function handleRequest(
  request: IncomingMessage,
  response: ServerResponse,
  options: RouterServerOptions,
  fetchImpl: typeof fetch
): Promise<void> {
  const url = new URL(request.url as string, "https://relay.local");

  if (request.method === "GET" && url.pathname === "/health") {
    sendJson(response, 200, { ok: true });
    return;
  }

  const asyncMode = url.pathname.startsWith("/api/async/");
  if (asyncMode) url.pathname = url.pathname.replace("/api/async/", "/api/");
  const wire = /\/(chat\/completions|responses)$/.exec(url.pathname);
  if (request.method === "POST" && wire !== null) {
    const attribution = matchMessagesPath(url.pathname.replace(/\/(chat\/completions|responses)$/, "/messages"));
    if (attribution !== null) {
      await handleWireRequest(request, response, options, fetchImpl, { ...attribution, asyncMode }, wire[1] as string);
      return;
    }
  }

  const messagesRoute =
    request.method === "POST" ? matchMessagesPath(url.pathname) : null;
  if (messagesRoute === null) {
    sendJson(response, 404, {
      type: "error",
      error: {
        type: "not_found_error",
        message: "Route not found"
      }
    });
    return;
  }
  const attribution = messagesRoute;

  const body = await readBody(request, DEFAULT_MAX_BODY_BYTES);
  const anthropicRequest = parseAnthropicRequest(body);
  const route = chooseRoute(
    anthropicRequest,
    options.routingConfigLoader.load(),
    attribution.escalated ? "test_failure_retry" : null
  );

  if (
    providerNameFor(route.routedModel) === OPENROUTER_PROVIDER_NAME &&
    (options.openRouterApiKey === undefined || options.openRouterApiKey.length === 0)
  ) {
    sendJson(response, 500, {
      type: "error",
      error: {
        type: "authentication_error",
        message: "OPENROUTER_API_KEY is required"
      }
    });
    return;
  }

  if (anthropicRequest.stream === true) {
    const upstreamResponse = await callUpstream(
      anthropicRequest,
      route,
      options,
      fetchImpl,
      attribution
    );
    const latencyMs = Date.now() - upstreamResponse.startedAt;

    if (!upstreamResponse.response.ok) {
      const errorMessage = await readUpstreamError(upstreamResponse.response);
      await recordCall(options.callLogSink, route, route.routedModel, latencyMs, 0, null, "error", errorMessage, attribution);
      sendJson(response, upstreamResponse.response.status, {
        type: "error",
        error: {
          type: "api_error",
          message: errorMessage
        }
      });
      return;
    }

    if (upstreamResponse.response.body === null) {
      const errorMessage = "OpenRouter returned an empty stream";
      await recordCall(
        options.callLogSink,
        route,
        route.routedModel,
        latencyMs,
        0,
        null,
        "error",
        errorMessage,
        attribution
      );
      sendJson(response, 502, {
        type: "error",
        error: {
          type: "api_error",
          message: errorMessage
        }
      });
      return;
    }

    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive"
    });

    let actualModel = route.routedModel;
    let completionTokens = 0;
    let costUsd: number | null = null;
    for await (const event of openAIStreamToAnthropicSse(
      upstreamResponse.response.body,
      route.routedModel,
      (summary) => {
        actualModel = summary.model;
        completionTokens = summary.completionTokens;
        costUsd = summary.costUsd;
      }
    )) {
      response.write(event);
    }

    await recordCall(
      options.callLogSink,
      route,
      actualModel,
      Date.now() - upstreamResponse.startedAt,
      completionTokens,
      costUsd,
      "success",
      null,
      attribution
    );
    response.end();
    return;
  }

  const result = await executeNonStreamingWithRetry(
    anthropicRequest,
    route,
    options,
    fetchImpl,
    attribution
  );

  if (result.response === undefined) {
    sendJson(response, result.status, {
      type: "error",
      error: {
        type: "api_error",
        message: result.errorMessage
      }
    });
    return;
  }

  sendJson(response, 200, fromOpenAIResponse(result.response));
}

type UpstreamAttempt = {
  response: Response;
  startedAt: number;
};

type NonStreamingResult =
  | {
      response: OpenAIChatCompletionResponse;
      status: 200;
      errorMessage: null;
    }
  | {
      response: undefined;
      status: number;
      errorMessage: string;
    };

type CallAttribution = {
  sessionId: string | null;
  runId: string | null;
  escalated: boolean;
  asyncMode?: boolean;
};

type NativeUsage = { model?: string; usage?: { completion_tokens?: number; output_tokens?: number; cost?: number }; response?: NativeUsage };
function updateNativeUsage(payload: NativeUsage, summary: { model: string; tokens: number; cost: number | null }): void {
  const value = payload.response ?? payload;
  summary.model = value.model ?? summary.model;
  if (value.usage) {
    summary.tokens = value.usage.completion_tokens ?? value.usage.output_tokens ?? summary.tokens;
    summary.cost = value.usage.cost ?? summary.cost;
  }
}

// Preserve each harness's native protocol, including reasoning and tool fields.
// Explicit provider-qualified models never escalate to a different source.
async function handleWireRequest(request: IncomingMessage, response: ServerResponse,
  options: RouterServerOptions, fetchImpl: typeof fetch, attribution: CallAttribution,
  protocol: string): Promise<void> {
  const body = JSON.parse(await readBody(request, DEFAULT_MAX_BODY_BYTES)) as Record<string, unknown>;
  if (typeof body.model !== "string") throw new Error("model is required");
  const route = chooseRoute({ model: body.model, max_tokens: options.maxCompletionTokens,
    messages: [{ role: "user", content: JSON.stringify(body) }] }, options.routingConfigLoader.load());
  const upstream = resolveUpstream(route.routedModel, options.routingConfigLoader.load(), options);
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (upstream.apiKey) headers.Authorization = `Bearer ${upstream.apiKey}`;
  if (providerNameFor(route.routedModel) === "openrouter" && !upstream.apiKey) throw new Error("OPENROUTER_API_KEY is required");
  const started = Date.now();
  const controller = new AbortController();
  response.on("close", () => controller.abort());
  if (attribution.asyncMode && (protocol !== "responses" || providerNameFor(route.routedModel) !== "doubleword" || attribution.sessionId === null || attribution.runId === null)) {
    throw new Error("Async inference requires a Codex thread using Doubleword Responses");
  }
  const result = attribution.asyncMode
    ? await executeAsyncResponse({ body: { ...body, model: upstream.model }, baseUrl: trimRight(upstream.baseUrl, "/"), headers,
        sessionId: attribution.sessionId as string, runId: attribution.runId as string, signal: controller.signal, fetchImpl, onJob: options.inferenceJobSink })
    : await fetchImpl(`${trimRight(upstream.baseUrl, "/")}/${protocol}`, {
        method: "POST", headers, body: JSON.stringify({ ...body, model: upstream.model })
      });
  if (!result.ok) {
    const error = await readUpstreamError(result);
    await recordCall(options.callLogSink, route, route.routedModel, Date.now() - started, 0, null, "error", error, attribution);
    sendJson(response, result.status, { error: { message: error } });
    return;
  }
  const summary = { model: route.routedModel, tokens: 0, cost: null as number | null };
  if (body.stream !== true) {
    const json = await result.json() as Record<string, unknown>;
    updateNativeUsage(json, summary);
    await recordCall(options.callLogSink, route, summary.model, Date.now() - started, summary.tokens, summary.cost, "success", null, attribution);
    sendJson(response, 200, json);
    return;
  }
  if (result.body === null) throw new Error("Upstream returned an empty stream");
  response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
  for await (const frame of parseSse(result.body)) {
    if (frame.data !== "[DONE]") {
      try { updateNativeUsage(JSON.parse(frame.data) as NativeUsage, summary); } catch { /* Non-JSON frames still pass through unchanged. */ }
    }
    response.write(`${frame.event === undefined ? "" : `event: ${frame.event}\n`}data: ${frame.data}\n\n`);
  }
  await recordCall(options.callLogSink, route, summary.model, Date.now() - started, summary.tokens, summary.cost, "success", null, attribution);
  response.end();
}

async function executeNonStreamingWithRetry(
  anthropicRequest: AnthropicMessagesRequest,
  initialRoute: RoutingDecision,
  options: RouterServerOptions,
  fetchImpl: typeof fetch,
  attribution: CallAttribution
): Promise<NonStreamingResult> {
  const attempts = [
    initialRoute,
    chooseRoute(
      anthropicRequest,
      options.routingConfigLoader.load(),
      "upstream_error_retry"
    )
  ];
  let lastStatus = 502;
  let lastError = "OpenRouter request failed";

  for (const route of uniqueRoutes(attempts)) {
    const attempt = await callUpstream(anthropicRequest, route, options, fetchImpl, attribution);
    const latencyMs = Date.now() - attempt.startedAt;

    if (!attempt.response.ok) {
      const errorMessage = await readUpstreamError(attempt.response);
      lastStatus = attempt.response.status;
      lastError = errorMessage;
      await recordCall(options.callLogSink, route, route.routedModel, latencyMs, 0, null, "error", errorMessage, attribution);
      continue;
    }

    try {
      const upstreamJson = (await attempt.response.json()) as unknown;
      const openAIResponse = assertOpenAIResponse(upstreamJson);
      const completionTokens = openAIResponse.usage?.completion_tokens ?? 0;
      await recordCall(
        options.callLogSink,
        route,
        openAIResponse.model,
        latencyMs,
        completionTokens,
        extractOpenRouterCostUsd(upstreamJson),
        "success",
        null,
        attribution
      );
      return { response: openAIResponse, status: 200, errorMessage: null };
    } catch (error: unknown) {
      lastStatus = 502;
      lastError = error instanceof Error ? error.message : "Invalid OpenRouter response";
      await recordCall(options.callLogSink, route, route.routedModel, latencyMs, 0, null, "error", lastError, attribution);
    }
  }

  return { response: undefined, status: lastStatus, errorMessage: lastError };
}

const OPENROUTER_PROVIDER_NAME = "openrouter";

// Name of the upstream that will actually receive the request: the built-in
// openrouter path when the routed model has no `name::` prefix, otherwise
// the custom provider name from the prefix. `openrouter` is a reserved
// provider name (routing.ts), so a prefixed model id is never mistaken for
// the built-in path.
function providerNameFor(modelId: string): string {
  const separatorIndex = modelId.indexOf("::");
  return separatorIndex === -1 ? OPENROUTER_PROVIDER_NAME : modelId.slice(0, separatorIndex);
}

async function callUpstream(
  anthropicRequest: AnthropicMessagesRequest,
  route: RoutingDecision,
  options: RouterServerOptions,
  fetchImpl: typeof fetch,
  attribution: CallAttribution
): Promise<UpstreamAttempt> {
  const startedAt = Date.now();
  const isOpenRouter = providerNameFor(route.routedModel) === OPENROUTER_PROVIDER_NAME;
  const upstream: ResolvedUpstream = resolveUpstream(route.routedModel, options.routingConfigLoader.load(), {
    openRouterBaseUrl: options.openRouterBaseUrl,
    openRouterApiKey: options.openRouterApiKey
  });
  const openAIRequest = toOpenAIRequest(anthropicRequest, {
    model: upstream.model,
    maxCompletionTokens: options.maxCompletionTokens
  });
  if (isOpenRouter && attribution.sessionId !== null) {
    openAIRequest.session_id = attribution.sessionId;
  }

  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (upstream.apiKey !== undefined && upstream.apiKey.length > 0) {
    headers.Authorization = `Bearer ${upstream.apiKey}`;
  }
  if (isOpenRouter) {
    headers["HTTP-Referer"] = options.referer;
    headers["X-OpenRouter-Title"] = options.title;
  }

  const response = await fetchImpl(`${trimRight(upstream.baseUrl, "/")}/chat/completions`, {
    method: "POST",
    headers,
    body: JSON.stringify(openAIRequest)
  });

  return { response, startedAt };
}

async function readUpstreamError(response: Response): Promise<string> {
  const errorBody = response.body === null ? response.statusText : await collectText(response.body);
  return errorBody.length > 0 ? errorBody : response.statusText;
}

async function recordCall(
  sink: CallLogSink | undefined,
  route: RoutingDecision,
  actualModel: string,
  latencyMs: number,
  completionTokens: number,
  costUsd: number | null,
  status: LlmCallRecord["status"],
  errorMessage: string | null,
  attribution: CallAttribution
): Promise<void> {
  if (sink === undefined) {
    return;
  }

  await sink.record({
    sessionId: attribution.sessionId,
    runId: attribution.runId,
    requestedModel: route.requestedModel,
    routeTarget: route.routeTarget,
    routedModel: actualModel,
    provider: providerNameFor(route.routedModel),
    tier: route.tier,
    promptTokens: route.promptTokens,
    completionTokens,
    costUsd,
    frontierCostUsd: estimateFrontierCostUsd(route.promptTokens, completionTokens),
    latencyMs,
    escalationReason: route.escalationReason,
    status,
    errorMessage,
    createdAt: new Date().toISOString()
  });
}

function uniqueRoutes(routes: RoutingDecision[]): RoutingDecision[] {
  return routes.filter((route, index) => {
    return routes.findIndex((candidate) => candidate.routedModel === route.routedModel) === index;
  });
}

function extractOpenRouterCostUsd(value: unknown): number | null {
  const record = value as Record<string, unknown>;
  const usage = record.usage;
  if (typeof usage !== "object" || usage === null || Array.isArray(usage)) {
    return null;
  }

  const cost = (usage as Record<string, unknown>).cost;
  return typeof cost === "number" ? cost : null;
}

function matchMessagesPath(pathname: string): CallAttribution | null {
  if (pathname === "/api/v1/messages") {
    return { sessionId: null, runId: null, escalated: false };
  }

  const runEscalatedMatch = /^\/api\/session\/([^/]+)\/run\/([^/]+)\/escalated\/v1\/messages$/.exec(pathname);
  if (runEscalatedMatch !== null) {
    return {
      sessionId: decodeURIComponent(runEscalatedMatch[1] as string),
      runId: decodeURIComponent(runEscalatedMatch[2] as string),
      escalated: true
    };
  }

  const runMatch = /^\/api\/session\/([^/]+)\/run\/([^/]+)\/v1\/messages$/.exec(pathname);
  if (runMatch !== null) {
    return {
      sessionId: decodeURIComponent(runMatch[1] as string),
      runId: decodeURIComponent(runMatch[2] as string),
      escalated: false
    };
  }

  const escalatedMatch = /^\/api\/session\/([^/]+)\/escalated\/v1\/messages$/.exec(pathname);
  if (escalatedMatch !== null) {
    return { sessionId: decodeURIComponent(escalatedMatch[1] as string), runId: null, escalated: true };
  }

  const match = /^\/api\/session\/([^/]+)\/v1\/messages$/.exec(pathname);
  if (match !== null) {
    return { sessionId: decodeURIComponent(match[1] as string), runId: null, escalated: false };
  }

  return null;
}

function parseAnthropicRequest(body: string): AnthropicMessagesRequest {
  const parsed: unknown = JSON.parse(body);

  if (!isAnthropicRequest(parsed)) {
    throw new Error("Invalid Anthropic Messages request");
  }

  return parsed;
}

function isAnthropicRequest(value: unknown): value is AnthropicMessagesRequest {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const record = value as Record<string, unknown>;
  return (
    typeof record.model === "string" &&
    typeof record.max_tokens === "number" &&
    Array.isArray(record.messages)
  );
}

function assertOpenAIResponse(value: unknown): OpenAIChatCompletionResponse {
  if (typeof value !== "object" || value === null) {
    throw new Error("Invalid OpenRouter response");
  }

  const record = value as Record<string, unknown>;
  if (
    typeof record.id !== "string" ||
    typeof record.model !== "string" ||
    !Array.isArray(record.choices)
  ) {
    throw new Error("Invalid OpenRouter response");
  }

  return value as OpenAIChatCompletionResponse;
}

function readBody(request: IncomingMessage, maxBytes: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let totalBytes = 0;
    let rejected = false;

    request.on("data", (chunk: Buffer) => {
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        rejected = true;
        reject(new Error("Request body too large"));
        return;
      }

      chunks.push(chunk);
    });

    request.on("end", () => {
      if (rejected) {
        return;
      }

      resolve(Buffer.concat(chunks).toString("utf8"));
    });

    request.on("error", reject);
  });
}

function sendJson(response: ServerResponse, statusCode: number, body: unknown): void {
  response.writeHead(statusCode, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(body));
}

function trimRight(value: string, suffix: string): string {
  let output = value;
  while (output.endsWith(suffix)) {
    output = output.slice(0, -suffix.length);
  }
  return output;
}
