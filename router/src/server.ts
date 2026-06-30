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
    openRouterModel: process.env.OPENROUTER_MODEL ?? "moonshotai/kimi-k2",
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
  const taskId = messagesRoute.taskId;

  if (options.openRouterApiKey === undefined || options.openRouterApiKey.length === 0) {
    sendJson(response, 500, {
      type: "error",
      error: {
        type: "authentication_error",
        message: "OPENROUTER_API_KEY is required"
      }
    });
    return;
  }

  const body = await readBody(request, DEFAULT_MAX_BODY_BYTES);
  const anthropicRequest = parseAnthropicRequest(body);
  const route = chooseRoute(anthropicRequest, options.routingConfigLoader.load());

  if (anthropicRequest.stream === true) {
    const upstreamResponse = await callOpenRouter(
      anthropicRequest,
      route,
      options,
      fetchImpl
    );
    const latencyMs = Date.now() - upstreamResponse.startedAt;

    if (!upstreamResponse.response.ok) {
      const errorMessage = await readUpstreamError(upstreamResponse.response);
      await recordCall(options.callLogSink, route, latencyMs, 0, null, "error", errorMessage, taskId);
      sendJson(response, upstreamResponse.response.status, {
        type: "error",
        error: {
          type: "api_error",
          message: errorMessage
        }
      });
      return;
    }

    await recordCall(options.callLogSink, route, latencyMs, 0, null, "success", null, taskId);

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
    taskId
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

async function executeNonStreamingWithRetry(
  anthropicRequest: AnthropicMessagesRequest,
  initialRoute: RoutingDecision,
  options: RouterServerOptions,
  fetchImpl: typeof fetch,
  taskId: string | null
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
    const attempt = await callOpenRouter(anthropicRequest, route, options, fetchImpl);
    const latencyMs = Date.now() - attempt.startedAt;

    if (!attempt.response.ok) {
      const errorMessage = await readUpstreamError(attempt.response);
      lastStatus = attempt.response.status;
      lastError = errorMessage;
      await recordCall(options.callLogSink, route, latencyMs, 0, null, "error", errorMessage, taskId);
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
        taskId
      );
      return { response: openAIResponse, status: 200, errorMessage: null };
    } catch (error: unknown) {
      lastStatus = 502;
      lastError = error instanceof Error ? error.message : "Invalid OpenRouter response";
      await recordCall(options.callLogSink, route, latencyMs, 0, null, "error", lastError, taskId);
    }
  }

  return { response: undefined, status: lastStatus, errorMessage: lastError };
}

async function callOpenRouter(
  anthropicRequest: AnthropicMessagesRequest,
  route: RoutingDecision,
  options: RouterServerOptions,
  fetchImpl: typeof fetch
): Promise<UpstreamAttempt> {
  const startedAt = Date.now();
  const openAIRequest = toOpenAIRequest(anthropicRequest, {
    model: route.routedModel,
    maxCompletionTokens: options.maxCompletionTokens
  });
  const response = await fetchImpl(`${trimRight(options.openRouterBaseUrl, "/")}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${options.openRouterApiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": options.referer,
      "X-OpenRouter-Title": options.title
    },
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
  taskId: string | null
): Promise<void> {
  if (sink === undefined) {
    return;
  }

  await sink.record({
    taskId,
    requestedModel: route.requestedModel,
    routedModel: route.routedModel,
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

function matchMessagesPath(pathname: string): { taskId: string | null } | null {
  if (pathname === "/api/v1/messages") {
    return { taskId: null };
  }

  const match = /^\/api\/task\/([^/]+)\/v1\/messages$/.exec(pathname);
  if (match !== null) {
    return { taskId: decodeURIComponent(match[1] as string) };
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
