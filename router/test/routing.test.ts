import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  FanOutCallLogSink,
  HttpCallLogSink,
  JsonlCallLogSink,
  MemoryCallLogSink,
  createCallLogSink,
  type LlmCallRecord
} from "../src/call-log.js";
import {
  chooseRoute,
  createRoutingConfigLoader,
  DEFAULT_ROUTING_CONFIG,
  estimateFrontierCostUsd,
  resolveUpstream,
  type RoutingConfig
} from "../src/routing.js";
import type { AnthropicMessagesRequest } from "../src/types.js";

describe("routing", () => {
  it("uses default routing when no config path is provided", () => {
    expect(createRoutingConfigLoader(undefined).load()).toEqual(DEFAULT_ROUTING_CONFIG);
    expect(createRoutingConfigLoader("").load()).toEqual(DEFAULT_ROUTING_CONFIG);
  });

  it("falls back to default routing when the config file does not exist", () => {
    const missing = join(tmpdir(), "relay-routing-missing-xyz.json");
    expect(createRoutingConfigLoader(missing).load()).toEqual(DEFAULT_ROUTING_CONFIG);
  });

  it("loads, caches, and reloads routing config files", async () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-routing-"));
    const path = join(dir, "routing.json");

    try {
      writeFileSync(
        path,
        JSON.stringify({
          tiers: { "0": ["cheap"], "1": ["default"], "2": ["frontier"] },
          rules: [{ when: "default", tier: 1 }],
          qualityDial: { default: 5 },
          frontierModel: "frontier",
          targets: {
            "openrouter-auto": { model: "openrouter/auto-beta" }
          }
        })
      );

      const loader = createRoutingConfigLoader(path);
      expect(loader.load().tiers["1"]).toEqual(["default"]);
      expect(loader.load().tiers["1"]).toEqual(["default"]);

      await new Promise((resolve) => setTimeout(resolve, 5));
      writeFileSync(
        path,
        JSON.stringify({
          tiers: { "0": ["cheap"], "1": ["changed"], "2": ["frontier"] },
          rules: [{ when: "default", tier: 1 }],
          qualityDial: { default: "not a number" },
          targets: { "openrouter-auto": { model: "openrouter/auto-beta" } }
        })
      );

      expect(loader.load().tiers["1"]).toEqual(["changed"]);
      expect(loader.load().qualityDial.default).toBe(5);
      expect(loader.load().frontierModel).toBe("frontier");
      expect(loader.load().targets).toEqual({
        "openrouter-auto": { model: "openrouter/auto-beta" }
      });

      const noDialPath = join(dir, "routing-no-dial.json");
      writeFileSync(
        noDialPath,
        JSON.stringify({
          tiers: { "0": ["cheap"], "1": ["default"] },
          rules: [{ when: "default", tier: 1 }],
          frontierModel: "default"
        })
      );
      expect(createRoutingConfigLoader(noDialPath).load().qualityDial.default).toBe(5);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("selects tiers using requested model, prompt size, dial, clamping, and escalation", () => {
    expect(
      chooseRoute(request({ model: "x-ai/grok-4.5" }), DEFAULT_ROUTING_CONFIG)
    ).toMatchObject({
      tier: 1,
      requestedModel: "x-ai/grok-4.5",
      routedModel: "x-ai/grok-4.5"
    });

    expect(chooseRoute(request({ model: "claude-3-5-haiku-20241022" }), DEFAULT_ROUTING_CONFIG)).toMatchObject({
      tier: 0,
      routedModel: "deepseek/deepseek-v4-flash"
    });
    expect(chooseRoute(request({ model: "deepseek-flash" }), DEFAULT_ROUTING_CONFIG)).toMatchObject({
      tier: 0,
      routedModel: "deepseek/deepseek-v4-flash"
    });
    expect(
      chooseRoute(request({ metadata: { qualityDial: 0 } }), DEFAULT_ROUTING_CONFIG)
    ).toMatchObject({
      tier: 0,
      qualityDial: 0
    });
    expect(
      chooseRoute(request({ metadata: { qualityDial: 10 } }), DEFAULT_ROUTING_CONFIG)
    ).toMatchObject({
      tier: 3,
      qualityDial: 10
    });
    expect(
      chooseRoute(
        request({ metadata: { qualityDial: 10 } }),
        DEFAULT_ROUTING_CONFIG,
        "upstream_error_retry"
      )
    ).toMatchObject({
      tier: 3,
      escalationReason: "upstream_error_retry"
    });

    const large = request({ content: "x".repeat(260_000) });
    expect(chooseRoute(large, DEFAULT_ROUTING_CONFIG)).toMatchObject({
      tier: 2,
      routedModel: "openai/gpt-5.6-terra"
    });
  });

  it("resolves named managed-router targets without changing legacy model entries", () => {
    const config: RoutingConfig = {
      tiers: { "0": ["direct-cheap"], "1": ["openrouter-auto", "direct-standard"] },
      rules: [{ when: "default", tier: 1 }],
      qualityDial: { default: 5 },
      frontierModel: "direct-standard",
      providers: {},
      targets: {
        "openrouter-auto": { model: "openrouter/auto-beta" },
        "openrouter-pareto-code": { model: "openrouter/pareto-code" }
      }
    };

    expect(chooseRoute(request({ model: "relay-auto" }), config)).toMatchObject({
      requestedModel: "relay-auto",
      routeTarget: "openrouter-auto",
      routedModel: "openrouter/auto-beta"
    });
    expect(chooseRoute(request({ model: "direct-standard" }), config)).toMatchObject({
      routeTarget: "direct-standard",
      routedModel: "direct-standard"
    });
  });

  it("validates malformed routing configs", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-routing-invalid-"));
    const path = join(dir, "routing.json");

    try {
      for (const invalid of [
        null,
        {},
        { tiers: {}, rules: [{ when: "default", tier: 1 }] },
        { tiers: { "0": [1] }, rules: [{ when: "default", tier: 1 }] },
        { tiers: { "0": ["model"] }, rules: "bad" },
        { tiers: { "0": ["model"] }, rules: [null] },
        { tiers: { "0": ["model"] }, rules: [{ when: "default" }] },
        { tiers: { "0": ["model"] }, rules: [{ when: "unknown", tier: 0 }] },
        { tiers: { "0": ["model"] }, rules: [{ when: "promptTokens > nope", tier: 0 }] },
        { tiers: { "0": ["model"] }, rules: [{ when: "requestedModel contains 'x'", tier: 0 }] },
        { tiers: { "0": ["target"] }, rules: [{ when: "default", tier: 0 }], targets: [] },
        { tiers: { "0": ["target"] }, rules: [{ when: "default", tier: 0 }], targets: { target: null } },
        { tiers: { "0": ["target"] }, rules: [{ when: "default", tier: 0 }], targets: { target: [] } },
        { tiers: { "0": ["target"] }, rules: [{ when: "default", tier: 0 }], targets: { target: "model" } },
        { tiers: { "0": ["target"] }, rules: [{ when: "default", tier: 0 }], targets: { target: {} } }
      ]) {
        writeFileSync(path, JSON.stringify(invalid));
        expect(() => createRoutingConfigLoader(path).load()).toThrow();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("estimates frontier cost", () => {
    expect(estimateFrontierCostUsd(1_000_000, 1_000_000)).toBe(35);
  });

  it("throws when direct configs are missing a matched route or tier model", () => {
    const noMatchedRule: RoutingConfig = {
      tiers: { "0": ["cheap"] },
      rules: [{ when: "requestedModel contains 'haiku'", tier: 0 }],
      qualityDial: { default: 5 },
      frontierModel: "cheap",
      providers: {}
    };
    expect(() => chooseRoute(request(), noMatchedRule)).toThrow("default rule");

    const emptyTier: RoutingConfig = {
      tiers: { "0": [] },
      rules: [{ when: "default", tier: 0 }],
      qualityDial: { default: 5 },
      frontierModel: "cheap",
      providers: {}
    };
    expect(() => chooseRoute(request(), emptyTier)).toThrow("has no models");
  });

  it("defaults providers to {} when absent from the config", () => {
    expect(DEFAULT_ROUTING_CONFIG.providers).toEqual({});

    const dir = mkdtempSync(join(tmpdir(), "relay-routing-providers-absent-"));
    const path = join(dir, "routing.json");
    try {
      writeFileSync(
        path,
        JSON.stringify({
          tiers: { "0": ["cheap"] },
          rules: [{ when: "default", tier: 0 }]
        })
      );
      expect(createRoutingConfigLoader(path).load().providers).toEqual({});
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("parses a valid providers map with inline apiKey, apiKeyEnv, and keyless entries", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-routing-providers-valid-"));
    const path = join(dir, "routing.json");
    try {
      writeFileSync(
        path,
        JSON.stringify({
          tiers: { "0": ["cheap"] },
          rules: [{ when: "default", tier: 0 }],
          providers: {
            myvllm: { baseUrl: "http://localhost:8000/v1" },
            together_ai: { baseUrl: "https://api.together.xyz/v1", apiKey: "sk-inline" },
            "fire-works": { baseUrl: "https://api.fireworks.ai/inference/v1", apiKeyEnv: "FIREWORKS_KEY" }
          }
        })
      );

      expect(createRoutingConfigLoader(path).load().providers).toEqual({
        myvllm: { baseUrl: "http://localhost:8000/v1" },
        together_ai: { baseUrl: "https://api.together.xyz/v1", apiKey: "sk-inline" },
        "fire-works": { baseUrl: "https://api.fireworks.ai/inference/v1", apiKeyEnv: "FIREWORKS_KEY" }
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects invalid providers maps", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-routing-providers-invalid-"));
    const path = join(dir, "routing.json");

    try {
      for (const invalid of [
        { tiers: { "0": ["m"] }, rules: [{ when: "default", tier: 0 }], providers: [] },
        { tiers: { "0": ["m"] }, rules: [{ when: "default", tier: 0 }], providers: null },
        {
          tiers: { "0": ["m"] },
          rules: [{ when: "default", tier: 0 }],
          providers: { "Bad Name": { baseUrl: "https://x.example" } }
        },
        {
          tiers: { "0": ["m"] },
          rules: [{ when: "default", tier: 0 }],
          providers: { openrouter: { baseUrl: "https://x.example" } }
        },
        {
          tiers: { "0": ["m"] },
          rules: [{ when: "default", tier: 0 }],
          providers: { myvllm: "not-an-object" }
        },
        {
          tiers: { "0": ["m"] },
          rules: [{ when: "default", tier: 0 }],
          providers: { myvllm: { baseUrl: "ftp://x.example" } }
        },
        {
          tiers: { "0": ["m"] },
          rules: [{ when: "default", tier: 0 }],
          providers: { myvllm: {} }
        }
      ]) {
        writeFileSync(path, JSON.stringify(invalid));
        expect(() => createRoutingConfigLoader(path).load()).toThrow();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("parses the pre-existing example routing config unchanged with providers defaulting to {}", () => {
    const exampleConfig: unknown = JSON.parse(
      readFileSync(join(import.meta.dirname, "..", "routing.example.json"), "utf8")
    );

    const dir = mkdtempSync(join(tmpdir(), "relay-routing-example-"));
    const path = join(dir, "routing.json");
    try {
      writeFileSync(path, JSON.stringify(exampleConfig));
      const parsed = createRoutingConfigLoader(path).load();

      expect(parsed).toEqual({
        ...(exampleConfig as object),
        providers: {}
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("resolveUpstream", () => {
  const config: RoutingConfig = {
    tiers: { "0": ["cheap"] },
    rules: [{ when: "default", tier: 0 }],
    qualityDial: { default: 5 },
    frontierModel: "cheap",
    providers: {
      myvllm: { baseUrl: "http://localhost:8000/v1" },
      withkey: { baseUrl: "https://api.example.com/v1", apiKey: "sk-inline" },
      withenv: { baseUrl: "https://api.example.com/v1", apiKeyEnv: "RESOLVE_UPSTREAM_TEST_KEY" }
    }
  };
  const options = { openRouterBaseUrl: "https://openrouter.ai/api/v1", openRouterApiKey: "sk-or" };

  it("returns the built-in openrouter upstream when the model has no '::'", () => {
    expect(resolveUpstream("openai/gpt-5.5", config, options)).toEqual({
      baseUrl: "https://openrouter.ai/api/v1",
      apiKey: "sk-or",
      model: "openai/gpt-5.5"
    });
  });

  it("resolves a keyless custom provider", () => {
    expect(resolveUpstream("myvllm::qwen3-32b", config, options)).toEqual({
      baseUrl: "http://localhost:8000/v1",
      apiKey: undefined,
      model: "qwen3-32b"
    });
  });

  it("resolves a custom provider with an inline apiKey", () => {
    expect(resolveUpstream("withkey::some-model", config, options)).toEqual({
      baseUrl: "https://api.example.com/v1",
      apiKey: "sk-inline",
      model: "some-model"
    });
  });

  it("resolves a custom provider's apiKey from apiKeyEnv", () => {
    process.env.RESOLVE_UPSTREAM_TEST_KEY = "env-secret";
    try {
      expect(resolveUpstream("withenv::some-model", config, options)).toEqual({
        baseUrl: "https://api.example.com/v1",
        apiKey: "env-secret",
        model: "some-model"
      });
    } finally {
      delete process.env.RESOLVE_UPSTREAM_TEST_KEY;
    }
  });

  it("throws for an unknown provider name", () => {
    expect(() => resolveUpstream("unknown::some-model", config, options)).toThrow(
      "Unknown provider 'unknown'"
    );
  });
});

describe("chooseRoute direct '::' routing", () => {
  const config: RoutingConfig = {
    tiers: { "0": ["cheap"], "1": ["default-model"], "2": ["myvllm::literal-model"] },
    rules: [{ when: "default", tier: 1 }],
    qualityDial: { default: 5 },
    frontierModel: "default-model",
    providers: {
      myvllm: { baseUrl: "http://localhost:8000/v1" }
    }
  };

  it("routes a '::' model that isn't a configured tier directly to itself using the default rule's tier", () => {
    expect(chooseRoute(request({ model: "myvllm::qwen3-32b" }), config)).toMatchObject({
      requestedModel: "myvllm::qwen3-32b",
      routedModel: "myvllm::qwen3-32b",
      tier: 1
    });
  });

  it("still prefers an exact tier match over direct '::' routing", () => {
    expect(chooseRoute(request({ model: "myvllm::literal-model" }), config)).toMatchObject({
      requestedModel: "myvllm::literal-model",
      routedModel: "myvllm::literal-model",
      tier: 2
    });
  });

  it("throws when a config without a default rule is used for direct '::' routing", () => {
    const noDefault: RoutingConfig = {
      tiers: { "0": ["cheap"] },
      rules: [{ when: "requestedModel contains 'haiku'", tier: 0 }],
      qualityDial: { default: 5 },
      frontierModel: "cheap",
      providers: { myvllm: { baseUrl: "http://localhost:8000/v1" } }
    };
    expect(() => chooseRoute(request({ model: "myvllm::llama" }), noDefault)).toThrow("default rule");
  });
});

describe("call log sinks", () => {
  it("writes JSONL call records", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-call-log-"));
    const path = join(dir, "calls.jsonl");

    try {
      const sink = new JsonlCallLogSink(path);
      sink.record({
        sessionId: null,
        requestedModel: "requested",
        routedModel: "routed",
        tier: 1,
        promptTokens: 10,
        completionTokens: 2,
        costUsd: 0.1,
        frontierCostUsd: 0.2,
        latencyMs: 3,
        escalationReason: null,
        status: "success",
        errorMessage: null,
        createdAt: "2026-06-11T00:00:00.000Z"
      });

      expect(JSON.parse(readFileSync(path, "utf8").trim())).toMatchObject({
        requestedModel: "requested",
        routedModel: "routed",
        status: "success"
      });
      expect(createCallLogSink(undefined)).toBeUndefined();
      expect(createCallLogSink("")).toBeUndefined();
      expect(createCallLogSink(path)).toBeInstanceOf(JsonlCallLogSink);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("createCallLogSink(options) returns undefined when no sinks configured", () => {
    expect(createCallLogSink({})).toBeUndefined();
    expect(createCallLogSink({ jsonlPath: "", httpUrl: "" })).toBeUndefined();
  });

  it("createCallLogSink(options) returns JsonlCallLogSink for jsonlPath only", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-"));
    try {
      const sink = createCallLogSink({ jsonlPath: join(dir, "out.jsonl") });
      expect(sink).toBeInstanceOf(JsonlCallLogSink);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("createCallLogSink(options) returns HttpCallLogSink for httpUrl only", () => {
    const sink = createCallLogSink({ httpUrl: "http://localhost:7777/internal/llm-calls" });
    expect(sink).toBeInstanceOf(HttpCallLogSink);
  });

  it("createCallLogSink(options) returns FanOutCallLogSink for both sinks", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-"));
    try {
      const sink = createCallLogSink({
        jsonlPath: join(dir, "out.jsonl"),
        httpUrl: "http://localhost:7777/internal/llm-calls"
      });
      expect(sink).toBeInstanceOf(FanOutCallLogSink);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

const sampleRecord: LlmCallRecord = {
  sessionId: "session-1",
  requestedModel: "deepseek-flash",
  routedModel: "openai/gpt-5.5",
  provider: "openrouter",
  tier: 1,
  promptTokens: 100,
  completionTokens: 50,
  costUsd: 0.001,
  frontierCostUsd: 0.005,
  latencyMs: 300,
  escalationReason: null,
  status: "success",
  errorMessage: null,
  createdAt: "2026-06-12T00:00:00.000Z"
};

describe("HttpCallLogSink", () => {
  it("POSTs the record as JSON with the bearer token", async () => {
    const requests: Request[] = [];
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(new Request(input, init));
      return new Response(JSON.stringify({ id: 1 }), { status: 201 });
    });

    const sink = new HttpCallLogSink(
      "http://127.0.0.1:7777/internal/llm-calls",
      "my-token",
      mockFetch as unknown as typeof fetch
    );
    await sink.record(sampleRecord);

    expect(requests).toHaveLength(1);
    const req = requests[0];
    expect(req.method).toBe("POST");
    expect(req.headers.get("Authorization")).toBe("Bearer my-token");
    expect(req.headers.get("Content-Type")).toBe("application/json");
    const body = JSON.parse(await req.text());
    expect(body).toMatchObject({ sessionId: "session-1", requestedModel: "deepseek-flash", status: "success" });
  });

  it("swallows network errors (Error instance) and logs to console.error", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const failFetch = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    });

    const sink = new HttpCallLogSink(
      "http://127.0.0.1:7777/internal/llm-calls",
      "tok",
      failFetch as unknown as typeof fetch
    );
    await expect(sink.record(sampleRecord)).resolves.toBeUndefined();
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining("failed to post call record"),
      expect.stringContaining("ECONNREFUSED")
    );
    errorSpy.mockRestore();
  });

  it("swallows non-Error throws and converts them to string", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const failFetch = vi.fn(async () => {
      // eslint-disable-next-line @typescript-eslint/only-throw-error
      throw "string error value";
    });

    const sink = new HttpCallLogSink(
      "http://127.0.0.1:7777/internal/llm-calls",
      "tok",
      failFetch as unknown as typeof fetch
    );
    await expect(sink.record(sampleRecord)).resolves.toBeUndefined();
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining("failed to post call record"),
      "string error value"
    );
    errorSpy.mockRestore();
  });
});

describe("FanOutCallLogSink", () => {
  it("delivers the record to every sink", async () => {
    const a = new MemoryCallLogSink();
    const b = new MemoryCallLogSink();
    const fanOut = new FanOutCallLogSink([a, b]);
    await fanOut.record(sampleRecord);
    expect(a.records).toHaveLength(1);
    expect(b.records).toHaveLength(1);
  });
});

function request(overrides: {
  model?: string;
  content?: string;
  metadata?: AnthropicMessagesRequest["metadata"];
} = {}): AnthropicMessagesRequest {
  return {
    model: overrides.model ?? "claude-sonnet-4-5",
    max_tokens: 100,
    metadata: overrides.metadata,
    messages: [
      {
        role: "user",
        content: overrides.content ?? "Say done"
      }
    ]
  };
}
