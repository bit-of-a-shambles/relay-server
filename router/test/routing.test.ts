import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { JsonlCallLogSink } from "../src/call-log.js";
import { createCallLogSink } from "../src/call-log.js";
import {
  chooseRoute,
  createRoutingConfigLoader,
  DEFAULT_ROUTING_CONFIG,
  estimateFrontierCostUsd,
  type RoutingConfig
} from "../src/routing.js";
import type { AnthropicMessagesRequest } from "../src/types.js";

describe("routing", () => {
  it("uses default routing when no config path is provided", () => {
    expect(createRoutingConfigLoader(undefined).load()).toEqual(DEFAULT_ROUTING_CONFIG);
    expect(createRoutingConfigLoader("").load()).toEqual(DEFAULT_ROUTING_CONFIG);
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
          frontierModel: "frontier"
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
          qualityDial: { default: "not a number" }
        })
      );

      expect(loader.load().tiers["1"]).toEqual(["changed"]);
      expect(loader.load().qualityDial.default).toBe(5);
      expect(loader.load().frontierModel).toBe("frontier");

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
    expect(chooseRoute(request({ model: "claude-haiku" }), DEFAULT_ROUTING_CONFIG)).toMatchObject({
      tier: 0,
      routedModel: "qwen/qwen3-coder-small"
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
      routedModel: "anthropic/claude-sonnet-latest"
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
        { tiers: { "0": ["model"] }, rules: [{ when: "requestedModel contains 'x'", tier: 0 }] }
      ]) {
        writeFileSync(path, JSON.stringify(invalid));
        expect(() => createRoutingConfigLoader(path).load()).toThrow();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("estimates frontier cost", () => {
    expect(estimateFrontierCostUsd(1_000_000, 1_000_000)).toBe(90);
  });

  it("throws when direct configs are missing a matched route or tier model", () => {
    const noMatchedRule: RoutingConfig = {
      tiers: { "0": ["cheap"] },
      rules: [{ when: "requestedModel contains 'haiku'", tier: 0 }],
      qualityDial: { default: 5 },
      frontierModel: "cheap"
    };
    expect(() => chooseRoute(request(), noMatchedRule)).toThrow("default rule");

    const emptyTier: RoutingConfig = {
      tiers: { "0": [] },
      rules: [{ when: "default", tier: 0 }],
      qualityDial: { default: 5 },
      frontierModel: "cheap"
    };
    expect(() => chooseRoute(request(), emptyTier)).toThrow("has no models");
  });
});

describe("call log sinks", () => {
  it("writes JSONL call records", () => {
    const dir = mkdtempSync(join(tmpdir(), "relay-call-log-"));
    const path = join(dir, "calls.jsonl");

    try {
      const sink = new JsonlCallLogSink(path);
      sink.record({
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
