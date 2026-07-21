import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { URL } from "node:url";
import { fromOpenAIResponse, toOpenAIRequest } from "./translate.js";
import type {
  AnthropicMessagesRequest,
  OpenAIChatCompletionResponse
} from "./types.js";
import { collectText, openAIStreamToAnthropicSse } from "./sse.js";
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
  const url = new URL(request.url as string, "http://relay.local");

  if (request.method === "GET" && url.pathname === "/health") {
    sendJson(response, 200, { ok: true });
    return;
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
      fetchImpl
    );
    const latencyMs = Date.now() - upstreamResponse.startedAt;

    if (!upstreamResponse.response.ok) {
      const errorMessage = await readUpstreamError(upstreamResponse.response);
      await recordCall(options.callLogSink, route, latencyMs, 0, null, "error", errorMessage, attribution);
      sendJson(response, upstreamResponse.response.status, {
        type: "error",
        error: {
          type: "api_error",
          message: errorMessage
        }
      });
      return;
    }

    await recordCall(options.callLogSink, route, latencyMs, 0, null, "success", null, attribution);

    if (upstreamResponse.response.body === null) {
      sendJson(response, 502, {
        type: "error",
        error: {
          type: "api_error",
          message: "OpenRouter returned an empty stream"
        }
      });
      return;
    }

    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive"
    });

    for await (const event of openAIStreamToAnthropicSse(
      upstreamResponse.response.body,
      route.routedModel
    )) {
      response.write(event);
    }

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
  escalated: boolean;
};

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
    const attempt = await callUpstream(anthropicRequest, route, options, fetchImpl);
    const latencyMs = Date.now() - attempt.startedAt;

    if (!attempt.response.ok) {
      const errorMessage = await readUpstreamError(attempt.response);
      lastStatus = attempt.response.status;
      lastError = errorMessage;
      await recordCall(options.callLogSink, route, latencyMs, 0, null, "error", errorMessage, attribution);
      continue;
    }

    try {
      const upstreamJson = (await attempt.response.json()) as unknown;
      const openAIResponse = assertOpenAIResponse(upstreamJson);
      const completionTokens = openAIResponse.usage?.completion_tokens ?? 0;
      await recordCall(
        options.callLogSink,
        route,
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
      await recordCall(options.callLogSink, route, latencyMs, 0, null, "error", lastError, attribution);
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
  fetchImpl: typeof fetch
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
    requestedModel: route.requestedModel,
    routedModel: route.routedModel,
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
    return { sessionId: null, escalated: false };
  }

  const escalatedMatch = /^\/api\/session\/([^/]+)\/escalated\/v1\/messages$/.exec(pathname);
  if (escalatedMatch !== null) {
    return { sessionId: decodeURIComponent(escalatedMatch[1] as string), escalated: true };
  }

  const match = /^\/api\/session\/([^/]+)\/v1\/messages$/.exec(pathname);
  if (match !== null) {
    return { sessionId: decodeURIComponent(match[1] as string), escalated: false };
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
