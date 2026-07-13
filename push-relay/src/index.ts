import { ApnsJwtCache, type ApnsJwtSecrets, type JwtFactory } from "./jwt.js";

export type PushCategory = "agent_finished" | "tests_finished" | "needs_review";
export type PushEnvironment = "sandbox" | "production";

export type PushRelayEnv = ApnsJwtSecrets & {
  RELAY_SHARED_SECRET: string;
};

export const ALERT_COPY: Record<PushCategory, string> = {
  agent_finished: "Relay: agent finished",
  tests_finished: "Relay: tests finished",
  needs_review: "Relay: needs review"
};

const CATEGORIES = new Set<string>(Object.keys(ALERT_COPY));
const ENVIRONMENTS = new Set<string>(["sandbox", "production"]);
export const MIN_DEVICE_TOKEN_LENGTH = 16;
export const MAX_DEVICE_TOKEN_LENGTH = 128;
export const MAX_BODY_BYTES = 1024;
export const RATE_LIMIT_WINDOW_MS = 60_000;
const MAX_TRACKED_TOKENS = 1024;
const MAX_GLOBAL_ATTEMPTS = 100;
const MAX_IN_FLIGHT = 32;
const APNS_TIMEOUT_MS = 5_000;

type PushPayload = {
  deviceToken: string;
  category: PushCategory;
  environment: PushEnvironment;
};

export type PushRelayOptions = {
  fetcher?: typeof fetch;
  now?: () => number;
  rateLimitWindowMs?: number;
  maxTrackedTokens?: number;
  maxGlobalAttempts?: number;
  maxInFlight?: number;
  apnsTimeoutMs?: number;
  jwtFactory?: JwtFactory;
};

function jsonResponse(body: Record<string, boolean | string>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isCategory(value: unknown): value is PushCategory {
  return typeof value === "string" && CATEGORIES.has(value);
}

function isEnvironment(value: unknown): value is PushEnvironment {
  return typeof value === "string" && ENVIRONMENTS.has(value);
}

function isDeviceToken(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length >= MIN_DEVICE_TOKEN_LENGTH &&
    value.length <= MAX_DEVICE_TOKEN_LENGTH &&
    value.length % 2 === 0 &&
    /^[0-9a-fA-F]+$/.test(value)
  );
}

function parsePayload(value: unknown): PushPayload | null {
  if (!isRecord(value)) {
    return null;
  }

  const keys = Object.keys(value);
  if (keys.length !== 3 || keys.some((key) => !["deviceToken", "category", "environment"].includes(key))) {
    return null;
  }

  const { deviceToken, category, environment } = value;
  if (
    !isDeviceToken(deviceToken) ||
    !isCategory(category) ||
    !isEnvironment(environment)
  ) {
    return null;
  }

  return { deviceToken, category, environment };
}

class DeliveryLimiter {
  private readonly successfulAt = new Map<string, number>();
  private readonly inFlight = new Set<string>();
  private readonly globalAttempts: number[] = [];

  public constructor(
    private readonly now: () => number,
    private readonly windowMs: number,
    private readonly maxTrackedTokens: number,
    private readonly maxGlobalAttempts: number,
    private readonly maxInFlight: number
  ) {}

  public reserve(deviceToken: string): boolean {
    const now = this.now();
    this.prune(now);
    if (
      this.inFlight.has(deviceToken) ||
      this.successfulAt.has(deviceToken) ||
      this.globalAttempts.length >= this.maxGlobalAttempts ||
      this.inFlight.size >= this.maxInFlight
    ) {
      return false;
    }

    this.inFlight.add(deviceToken);
    this.globalAttempts.push(now);
    return true;
  }

  public commit(deviceToken: string): void {
    this.inFlight.delete(deviceToken);
    const now = this.now();
    this.successfulAt.delete(deviceToken);
    this.successfulAt.set(deviceToken, now);
    while (this.successfulAt.size > this.maxTrackedTokens) {
      const oldest = this.successfulAt.keys().next().value as string;
      this.successfulAt.delete(oldest);
    }
  }

  public release(deviceToken: string): void {
    this.inFlight.delete(deviceToken);
  }

  private prune(now: number): void {
    while (
      this.globalAttempts[0] !== undefined &&
      now - this.globalAttempts[0] >= this.windowMs
    ) {
      this.globalAttempts.shift();
    }
    for (const [deviceToken, timestamp] of this.successfulAt) {
      if (now - timestamp >= this.windowMs) {
        this.successfulAt.delete(deviceToken);
      }
    }
  }
}

type BodyRead = { text: string } | { tooLarge: true };

async function readBoundedBody(request: Request): Promise<BodyRead> {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null) {
    const declaredLength = Number(contentLength);
    if (
      !Number.isSafeInteger(declaredLength) ||
      declaredLength < 0 ||
      declaredLength > MAX_BODY_BYTES
    ) {
      return { tooLarge: true };
    }
  }

  if (request.body === null) {
    return { text: "" };
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) {
      break;
    }
    totalBytes += result.value.byteLength;
    if (totalBytes > MAX_BODY_BYTES) {
      await reader.cancel();
      return { tooLarge: true };
    }
    chunks.push(result.value);
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { text: new TextDecoder().decode(bytes) };
}

function parseJsonBody(body: string): PushPayload | null {
  try {
    return parsePayload(JSON.parse(body) as unknown);
  } catch {
    return null;
  }
}

async function timingSafeEqual(left: string, right: string): Promise<boolean> {
  const [leftDigest, rightDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(left)),
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(right))
  ]);
  const leftBytes = new Uint8Array(leftDigest);
  const rightBytes = new Uint8Array(rightDigest);
  let difference = leftBytes.length ^ rightBytes.length;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index]! ^ rightBytes[index]!;
  }
  return difference === 0;
}

async function isAuthorized(request: Request, sharedSecret: string): Promise<boolean> {
  const authorization = request.headers.get("Authorization");
  if (authorization === null) {
    return false;
  }
  const parts = authorization.split(" ");
  if (parts.length !== 2 || parts[0] !== "Bearer" || parts[1] === "") {
    return false;
  }
  return timingSafeEqual(parts[1]!, sharedSecret);
}

function apnsUrl(payload: PushPayload): string {
  const host = payload.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return `https://${host}/3/device/${payload.deviceToken}`;
}

class ApnsTimeoutError extends Error {}

async function fetchWithDeadline(
  fetcher: typeof fetch,
  input: RequestInfo | URL,
  init: RequestInit,
  timeoutMs: number
): Promise<Response> {
  const controller = new AbortController();
  let timeoutId = 0;
  const deadline = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      reject(new ApnsTimeoutError());
      controller.abort();
    }, timeoutMs);
  });

  try {
    return await Promise.race([
      fetcher(input, { ...init, signal: controller.signal }),
      deadline
    ]);
  } finally {
    clearTimeout(timeoutId);
  }
}

export function createPushRelay(options: PushRelayOptions = {}): ExportedHandler<PushRelayEnv> {
  const fetcher = options.fetcher ?? ((input: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(input, init));
  const now = options.now ?? (() => Date.now());
  const limiter = new DeliveryLimiter(
    now,
    options.rateLimitWindowMs ?? RATE_LIMIT_WINDOW_MS,
    options.maxTrackedTokens ?? MAX_TRACKED_TOKENS,
    options.maxGlobalAttempts ?? MAX_GLOBAL_ATTEMPTS,
    options.maxInFlight ?? MAX_IN_FLIGHT
  );
  const jwtCache = new ApnsJwtCache(options.jwtFactory);
  const apnsTimeoutMs = options.apnsTimeoutMs ?? APNS_TIMEOUT_MS;

  return {
    async fetch(request, env): Promise<Response> {
      const url = new URL(request.url);
      if (url.pathname !== "/push") {
        return jsonResponse({ error: "not_found" }, 404);
      }
      if (request.method !== "POST") {
        return jsonResponse({ error: "method_not_allowed" }, 405);
      }

      if (!env.RELAY_SHARED_SECRET) {
        return jsonResponse({ error: "relay_not_configured" }, 500);
      }
      if (!(await isAuthorized(request, env.RELAY_SHARED_SECRET))) {
        return jsonResponse({ error: "unauthorized" }, 401);
      }

      let body: BodyRead;
      try {
        body = await readBoundedBody(request);
      } catch {
        return jsonResponse({ error: "invalid_request" }, 400);
      }
      if ("tooLarge" in body) {
        return jsonResponse({ error: "request_too_large" }, 413);
      }
      const payload = parseJsonBody(body.text);
      if (payload === null) {
        return jsonResponse({ error: "invalid_request" }, 400);
      }
      if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
        return jsonResponse({ error: "relay_not_configured" }, 500);
      }
      if (!limiter.reserve(payload.deviceToken)) {
        return jsonResponse({ error: "rate_limited" }, 429);
      }

      try {
        const jwt = await jwtCache.get(env, Math.floor(now() / 1000));
        const response = await fetchWithDeadline(fetcher, apnsUrl(payload), {
          method: "POST",
          headers: {
            Authorization: `bearer ${jwt}`,
            "Content-Type": "application/json",
            "apns-expiration": "0",
            "apns-push-type": "alert",
            "apns-topic": "dev.relay.ios"
          },
          body: JSON.stringify({
            aps: {
              alert: ALERT_COPY[payload.category],
              sound: "default"
            }
          })
        }, apnsTimeoutMs);

        if (!response.ok) {
          limiter.release(payload.deviceToken);
          return jsonResponse({ error: "apns_rejected" }, 502);
        }
        limiter.commit(payload.deviceToken);
        return jsonResponse({ ok: true }, 200);
      } catch (error: unknown) {
        limiter.release(payload.deviceToken);
        return error instanceof ApnsTimeoutError
          ? jsonResponse({ error: "upstream_timeout" }, 502)
          : jsonResponse({ error: "upstream_unavailable" }, 502);
      }
    }
  };
}

export default createPushRelay();
