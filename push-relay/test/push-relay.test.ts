import { beforeAll, describe, expect, it, vi } from "vitest";
import worker, {
  MAX_BODY_BYTES,
  MAX_DEVICE_TOKEN_LENGTH,
  MIN_DEVICE_TOKEN_LENGTH,
  createPushRelay,
  type PushRelayEnv,
  type PushRelayOptions
} from "../src/index.js";
import { ApnsJwtCache, createApnsJwt } from "../src/jwt.js";

const DEVICE_TOKEN = "a".repeat(64);
const SECOND_DEVICE_TOKEN = "b".repeat(64);
const SHORT_DEVICE_TOKEN = "c".repeat(MIN_DEVICE_TOKEN_LENGTH);
const LONG_DEVICE_TOKEN = "d".repeat(MAX_DEVICE_TOKEN_LENGTH);
const SHARED_SECRET = "relay-test-shared-secret";
const ISSUED_AT = 1_725_000_000;

let keyPair: CryptoKeyPair;
let keyP8: string;

function encodeBase64(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function base64UrlDecode(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (value.length % 4)) % 4);
  const decoded = atob(padded);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function env(): PushRelayEnv {
  return {
    APNS_KEY_P8: keyP8,
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    RELAY_SHARED_SECRET: SHARED_SECRET
  };
}

function request(body: unknown, headers?: HeadersInit): Request {
  return new Request("https://relay.example/push", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SHARED_SECRET}`,
      "Content-Type": "application/json",
      ...headers
    },
    body: JSON.stringify(body)
  });
}

function validBody(deviceToken = DEVICE_TOKEN, category = "agent_finished", environment = "production") {
  return { deviceToken, category, environment };
}

async function invoke(
  fetcher: typeof fetch,
  body: unknown = validBody(),
  options: Omit<PushRelayOptions, "fetcher"> = {}
): Promise<{ response: Response; requests: Array<{ input: RequestInfo | URL; init?: RequestInit }> }> {
  const requests: Array<{ input: RequestInfo | URL; init?: RequestInit }> = [];
  const recordingFetcher: typeof fetch = async (input, init) => {
    requests.push({ input, init });
    return fetcher(input, init);
  };
  const relay = createPushRelay({ fetcher: recordingFetcher, ...options });
  const response = await relay.fetch(request(body), env());
  return { response, requests };
}

beforeAll(async () => {
  keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );
  keyP8 = `-----BEGIN PRIVATE KEY-----\n${encodeBase64(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey))}\n-----END PRIVATE KEY-----`;
});

describe("APNs JWT", () => {
  it("contains the APNs claims and a verifiable ES256 signature", async () => {
    const jwt = await createApnsJwt(env(), ISSUED_AT);
    const [encodedHeader, encodedClaims, encodedSignature] = jwt.split(".");
    const header = JSON.parse(new TextDecoder().decode(base64UrlDecode(encodedHeader ?? ""))) as Record<string, unknown>;
    const claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(encodedClaims ?? ""))) as Record<string, unknown>;
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keyPair.publicKey,
      base64UrlDecode(encodedSignature ?? ""),
      new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`)
    );

    expect(header).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(claims).toEqual({ iss: "TEAM123456", iat: ISSUED_AT });
    expect(valid).toBe(true);
  });
});

describe("APNs JWT cache", () => {
  it("reuses concurrent work and rotates after the refresh interval", async () => {
    const factory = vi.fn(async (_secrets: PushRelayEnv, issuedAtSeconds: number) => `jwt-${issuedAtSeconds}`);
    const cache = new ApnsJwtCache(factory, 3_000);
    const first = cache.get(env(), 1_000);
    const concurrent = cache.get(env(), 1_000);

    expect(concurrent).toBe(first);
    await expect(first).resolves.toBe("jwt-1000");
    await expect(cache.get(env(), 3_999)).resolves.toBe("jwt-1000");
    await expect(cache.get(env(), 4_000)).resolves.toBe("jwt-4000");
    expect(factory).toHaveBeenCalledTimes(2);
  });

  it("releases a failed signing promise so the next request can retry", async () => {
    let attempts = 0;
    const factory = vi.fn(async () => {
      attempts += 1;
      if (attempts === 1) {
        throw new Error("signing failed");
      }
      return "recovered-jwt";
    });
    const cache = new ApnsJwtCache(factory);

    await expect(cache.get(env(), 1_000)).rejects.toThrow("signing failed");
    await expect(cache.get(env(), 1_001)).resolves.toBe("recovered-jwt");
  });
});

describe("push relay", () => {
  it("forwards fixed copy, a cached JWT, APNs headers, and no caller text", async () => {
    const { response, requests } = await invoke(async () => new Response(null, { status: 200 }), validBody());
    const forwarded = requests[0];
    const forwardedHeaders = new Headers(forwarded?.init?.headers);
    const forwardedBody = JSON.parse(String(forwarded?.init?.body)) as Record<string, unknown>;
    const forwardedAuthorization = forwardedHeaders.get("authorization") ?? "";

    expect(response.status).toBe(200);
    expect(JSON.stringify(await response.json())).not.toContain(DEVICE_TOKEN);
    expect(forwarded?.input).toBe(`https://api.push.apple.com/3/device/${DEVICE_TOKEN}`);
    expect(forwarded?.init?.method).toBe("POST");
    expect(forwardedHeaders.get("content-type")).toBe("application/json");
    expect(forwardedHeaders.get("apns-expiration")).toBe("0");
    expect(forwardedHeaders.get("apns-push-type")).toBe("alert");
    expect(forwardedHeaders.get("apns-topic")).toBe("dev.relay.ios");
    expect(forwardedAuthorization).toMatch(/^bearer [^.]+\.[^.]+\.[^.]+$/);
    expect(forwardedAuthorization).not.toContain(SHARED_SECRET);
    expect(forwardedBody).toEqual({
      aps: { alert: "Relay: agent finished", sound: "default" }
    });
    expect(String(forwarded?.init?.body)).not.toContain("caller text");
    expect(String(forwarded?.init?.body)).not.toContain(DEVICE_TOKEN);
  });

  it.each([
    ["tests_finished", "Relay: tests finished"],
    ["needs_review", "Relay: needs review"]
  ] as const)("uses fixed copy for %s", async (category, body) => {
    const { requests } = await invoke(
      async () => new Response(null, { status: 200 }),
      validBody(DEVICE_TOKEN, category)
    );
    const forwardedBody = JSON.parse(String(requests[0]?.init?.body)) as { aps: { alert: string } };
    expect(forwardedBody.aps.alert).toBe(body);
  });

  it("uses the sandbox APNs endpoint and accepts bounded variable token lengths", async () => {
    const short = await invoke(async () => new Response(null, { status: 200 }), validBody(SHORT_DEVICE_TOKEN, "agent_finished", "sandbox"));
    const long = await invoke(async () => new Response(null, { status: 200 }), validBody(LONG_DEVICE_TOKEN));

    expect(short.response.status).toBe(200);
    expect(short.requests[0]?.input).toBe(`https://api.sandbox.push.apple.com/3/device/${SHORT_DEVICE_TOKEN}`);
    expect(long.response.status).toBe(200);
    expect(long.requests[0]?.input).toBe(`https://api.push.apple.com/3/device/${LONG_DEVICE_TOKEN}`);
  });

  it("rejects malformed JSON, shapes, categories, environments, and tokens", async () => {
    const relay = createPushRelay({ fetcher: async () => new Response(null, { status: 200 }) });
    const malformedJson = await relay.fetch(
      new Request("https://relay.example/push", {
        method: "POST",
        headers: { Authorization: `Bearer ${SHARED_SECRET}` },
        body: "{"
      }),
      env()
    );
    const cases: unknown[] = [
      null,
      [],
      "body",
      {},
      { ...validBody(), extra: "rejected" },
      validBody("a".repeat(MIN_DEVICE_TOKEN_LENGTH - 2)),
      validBody("a".repeat(MAX_DEVICE_TOKEN_LENGTH + 2)),
      validBody("a".repeat(MIN_DEVICE_TOKEN_LENGTH + 1)),
      validBody("g".repeat(MIN_DEVICE_TOKEN_LENGTH)),
      validBody(DEVICE_TOKEN, "unknown"),
      validBody(DEVICE_TOKEN, "agent_finished", "unknown")
    ];

    expect(malformedJson.status).toBe(400);
    for (const body of cases) {
      const response = await relay.fetch(request(body), env());
      expect(response.status).toBe(400);
    }
  });

  it("requires the shared bearer secret before reading the body", async () => {
    const relay = createPushRelay({ fetcher: async () => new Response(null, { status: 200 }) });
    const cases = [
      undefined,
      "Basic credentials",
      "Bearer",
      `Bearer ${SHARED_SECRET} extra`,
      "Bearer ",
      "Bearer relay-test-shared-secreu"
    ];

    for (const authorization of cases) {
      const unauthorizedRequest = new Request("https://relay.example/push", {
        method: "POST",
        headers: authorization === undefined ? {} : { Authorization: authorization },
        body: "not-json"
      });
      const response = await relay.fetch(unauthorizedRequest, env());
      expect(response.status).toBe(401);
      expect(unauthorizedRequest.bodyUsed).toBe(false);
    }

    const missingSecret = await relay.fetch(request(validBody()), { ...env(), RELAY_SHARED_SECRET: "" });
    expect(missingSecret.status).toBe(500);
  });

  it("rejects oversized bodies before JSON parsing, with or without Content-Length", async () => {
    const relay = createPushRelay({ fetcher: async () => new Response(null, { status: 200 }) });
    const declaredValid = request(validBody(), { "Content-Length": String(MAX_BODY_BYTES) });
    const declaredTooLarge = request(validBody(), { "Content-Length": String(MAX_BODY_BYTES + 1) });
    const streamedTooLarge = request("x".repeat(MAX_BODY_BYTES + 1));
    const emptyBody = new Request("https://relay.example/push", {
      method: "POST",
      headers: { Authorization: `Bearer ${SHARED_SECRET}` }
    });
    const brokenStream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.error(new Error("body stream failed"));
      }
    });
    const brokenBody = new Request("https://relay.example/push", {
      method: "POST",
      headers: { Authorization: `Bearer ${SHARED_SECRET}` },
      body: brokenStream,
      duplex: "half"
    } as RequestInit & { duplex: "half" });

    const declaredValidResponse = await relay.fetch(declaredValid, env());
    const declaredResponse = await relay.fetch(declaredTooLarge, env());
    const streamedResponse = await relay.fetch(streamedTooLarge, env());
    const emptyResponse = await relay.fetch(emptyBody, env());
    const brokenResponse = await relay.fetch(brokenBody, env());

    expect(declaredValidResponse.status).toBe(200);
    expect(declaredResponse.status).toBe(413);
    expect(streamedResponse.status).toBe(413);
    expect(emptyResponse.status).toBe(400);
    expect(brokenResponse.status).toBe(400);
    expect(declaredTooLarge.bodyUsed).toBe(false);
  });

  it("rejects non-POST methods and unknown paths", async () => {
    const relay = createPushRelay({ fetcher: async () => new Response(null, { status: 200 }) });
    const getResponse = await relay.fetch(new Request("https://relay.example/push"), env());
    const notFoundResponse = await relay.fetch(new Request("https://relay.example/other", { method: "POST" }), env());

    expect(getResponse.status).toBe(405);
    expect(notFoundResponse.status).toBe(404);
  });

  it("commits only successful deliveries and releases failed attempts", async () => {
    const statuses = [400, 200];
    const relay = createPushRelay({ fetcher: async () => new Response(null, { status: statuses.shift() ?? 500 }) });
    const failed = await relay.fetch(request(validBody()), env());
    const retried = await relay.fetch(request(validBody()), env());

    expect(failed.status).toBe(502);
    expect(retried.status).toBe(200);
  });

  it("rate-limits a second sequential successful delivery to the same token", async () => {
    const fetcher = vi.fn(async () => new Response(null, { status: 200 }));
    const relay = createPushRelay({ fetcher });

    const first = await relay.fetch(request(validBody()), env());
    const second = await relay.fetch(request(validBody()), env());

    expect(first.status).toBe(200);
    expect(second.status).toBe(429);
    expect(fetcher).toHaveBeenCalledOnce();
  });

  it("counts every failed APNs attempt against the global budget", async () => {
    let attempt = 0;
    const fetcher = vi.fn(async () => {
      attempt += 1;
      if (attempt === 1) {
        return new Response(null, { status: 400 });
      }
      if (attempt === 2) {
        return new Response(null, { status: 500 });
      }
      throw new Error("network failure");
    });
    const relay = createPushRelay({ fetcher, maxGlobalAttempts: 3 });

    const clientFailure = await relay.fetch(request(validBody()), env());
    const serverFailure = await relay.fetch(request(validBody()), env());
    const networkFailure = await relay.fetch(request(validBody()), env());
    const exhausted = await relay.fetch(request(validBody()), env());

    expect(clientFailure.status).toBe(502);
    expect(serverFailure.status).toBe(502);
    expect(networkFailure.status).toBe(502);
    expect(exhausted.status).toBe(429);
    expect(fetcher).toHaveBeenCalledTimes(3);
  });

  it("aborts APNs at the deadline and releases the token for a later retry", async () => {
    vi.useFakeTimers();
    try {
      let attempt = 0;
      let firstSignal: AbortSignal | null = null;
      const fetcher = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
        attempt += 1;
        if (attempt === 1) {
          firstSignal = init?.signal ?? null;
          return new Promise<Response>(() => undefined);
        }
        return Promise.resolve(new Response(null, { status: 200 }));
      });
      const relay = createPushRelay({
        fetcher,
        jwtFactory: async () => "cached.jwt",
        apnsTimeoutMs: 25,
        maxGlobalAttempts: 3
      });
      const firstPromise = relay.fetch(request(validBody()), env());
      await vi.waitFor(() => {
        expect(fetcher).toHaveBeenCalledOnce();
      });
      const observed = Promise.race([
        firstPromise,
        new Promise<"deadline_missed">((resolve) => {
          setTimeout(() => resolve("deadline_missed"), 50);
        })
      ]);

      await vi.advanceTimersByTimeAsync(50);
      const first = await observed;
      expect(first).toBeInstanceOf(Response);
      expect((first as Response).status).toBe(502);
      expect(await (first as Response).json()).toEqual({ error: "upstream_timeout" });
      expect(firstSignal?.aborted).toBe(true);

      const retry = await relay.fetch(request(validBody()), env());
      expect(retry.status).toBe(200);
      expect(fetcher).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("applies bounded TTL/LRU token limits and a global attempt limit", async () => {
    let now = 1_000;
    const relay = createPushRelay({
      fetcher: async () => new Response(null, { status: 200 }),
      now: () => now,
      rateLimitWindowMs: 100,
      maxTrackedTokens: 2,
      maxGlobalAttempts: 10
    });
    expect((await relay.fetch(request(validBody()), env())).status).toBe(200);
    expect((await relay.fetch(request(validBody(SECOND_DEVICE_TOKEN)), env())).status).toBe(200);
    expect((await relay.fetch(request(validBody("c".repeat(16))), env())).status).toBe(200);
    expect((await relay.fetch(request(validBody()), env())).status).toBe(200);
    now += 100;
    expect((await relay.fetch(request(validBody(SECOND_DEVICE_TOKEN)), env())).status).toBe(200);

    const globalRelay = createPushRelay({
      fetcher: async () => new Response(null, { status: 200 }),
      maxGlobalAttempts: 2
    });
    expect((await globalRelay.fetch(request(validBody()), env())).status).toBe(200);
    expect((await globalRelay.fetch(request(validBody(SECOND_DEVICE_TOKEN)), env())).status).toBe(200);
    expect((await globalRelay.fetch(request(validBody("c".repeat(16))), env())).status).toBe(429);
  });

  it("rejects concurrent abuse while an APNs delivery is in flight", async () => {
    let release = () => undefined;
    const fetcher = vi.fn(() => new Promise<Response>((resolve) => {
      release = () => resolve(new Response(null, { status: 200 }));
    }));
    const relay = createPushRelay({
      fetcher,
      jwtFactory: async () => "cached.jwt",
      maxInFlight: 1
    });
    const firstPromise = relay.fetch(request(validBody()), env());
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    const sameToken = await relay.fetch(request(validBody()), env());
    const otherToken = await relay.fetch(request(validBody(SECOND_DEVICE_TOKEN)), env());
    release();
    const first = await firstPromise;

    expect(fetcher).toHaveBeenCalledOnce();
    expect(sameToken.status).toBe(429);
    expect(otherToken.status).toBe(429);
    expect(first.status).toBe(200);
  });

  it("returns controlled errors for missing APNs secrets, rejection, and fetch failure", async () => {
    const missingSecrets = createPushRelay({ fetcher: async () => new Response(null, { status: 200 }) });
    const missingEnv = await missingSecrets.fetch(request(validBody()), {
      ...env(),
      APNS_KEY_P8: ""
    });
    const rejected = await invoke(async () => new Response(null, { status: 400 }));
    const failed = await invoke(async () => {
      throw new Error("network failure");
    }, validBody(SECOND_DEVICE_TOKEN, "tests_finished"));

    expect(missingEnv.status).toBe(500);
    expect(rejected.response.status).toBe(502);
    expect(failed.response.status).toBe(502);
    expect(await rejected.response.json()).toEqual({ error: "apns_rejected" });
    expect(await failed.response.json()).toEqual({ error: "upstream_unavailable" });
  });

  it("exports the default worker using the global fetch", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const response = await worker.fetch(request(validBody(SECOND_DEVICE_TOKEN, "needs_review")), env());
    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledOnce();
  });
});
