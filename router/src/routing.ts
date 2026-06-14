import { readFileSync, statSync } from "node:fs";
import type { AnthropicMessagesRequest, JsonObject } from "./types.js";

export type RoutingRule =
  | { when: "default"; tier: number }
  | { when: `requestedModel contains '${string}'`; tier: number }
  | { when: `promptTokens > ${number}`; tier: number };

export type RoutingConfig = {
  tiers: Record<string, string[]>;
  rules: RoutingRule[];
  qualityDial: {
    default: number;
  };
  frontierModel: string;
};

export type RoutingDecision = {
  requestedModel: string;
  routedModel: string;
  tier: number;
  promptTokens: number;
  qualityDial: number;
  frontierModel: string;
  escalationReason: string | null;
};

export type RoutingConfigLoader = {
  load: () => RoutingConfig;
};

export const DEFAULT_ROUTING_CONFIG: RoutingConfig = {
  tiers: {
    "0": ["qwen/qwen3-coder-small"],
    "1": ["moonshotai/kimi-k2", "deepseek/deepseek-chat"],
    "2": ["anthropic/claude-sonnet-latest"],
    "3": ["anthropic/claude-opus-latest"]
  },
  rules: [
    { when: "requestedModel contains 'haiku'", tier: 0 },
    { when: "promptTokens > 60000", tier: 2 },
    { when: "default", tier: 1 }
  ],
  qualityDial: {
    default: 5
  },
  frontierModel: "anthropic/claude-opus-latest"
};

export function createRoutingConfigLoader(path: string | undefined): RoutingConfigLoader {
  if (path === undefined || path.length === 0) {
    return { load: () => DEFAULT_ROUTING_CONFIG };
  }

  let cached: { mtimeMs: number; config: RoutingConfig } | undefined;

  return {
    load: () => {
      let mtimeMs: number;
      try {
        mtimeMs = statSync(path).mtimeMs;
      } catch {
        // Config not written yet (the daemon writes it from learned outcomes).
        // Stay up on the built-in default until it appears.
        return DEFAULT_ROUTING_CONFIG;
      }
      if (cached !== undefined && cached.mtimeMs === mtimeMs) {
        return cached.config;
      }

      const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
      const config = parseRoutingConfig(parsed);
      cached = { mtimeMs, config };
      return config;
    }
  };
}

export function chooseRoute(
  request: AnthropicMessagesRequest,
  config: RoutingConfig,
  escalationReason: string | null = null
): RoutingDecision {
  const promptTokens = estimatePromptTokens(request);
  const qualityDial = readQualityDial(request.metadata, config.qualityDial.default);
  const baseTier = findBaseTier(request.model, promptTokens, config.rules);
  const tier = clampTier(
    baseTier + Math.round((qualityDial - 5) / 3) + (escalationReason === null ? 0 : 1),
    config
  );
  const routedModel = firstModelForTier(config, tier);

  return {
    requestedModel: request.model,
    routedModel,
    tier,
    promptTokens,
    qualityDial,
    frontierModel: config.frontierModel,
    escalationReason
  };
}

export function estimateFrontierCostUsd(
  promptTokens: number,
  completionTokens: number
): number {
  const inputPerMillion = 15;
  const outputPerMillion = 75;
  return (promptTokens * inputPerMillion + completionTokens * outputPerMillion) / 1_000_000;
}

function parseRoutingConfig(value: unknown): RoutingConfig {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Invalid routing config");
  }

  const record = value as Record<string, unknown>;
  const tiers = parseTiers(record.tiers);
  const rules = parseRules(record.rules);
  const defaultDial = parseDefaultDial(record.qualityDial);
  const frontierModel =
    typeof record.frontierModel === "string" && record.frontierModel.length > 0
      ? record.frontierModel
      : firstModelForTier({ tiers }, maxTier(tiers));

  return {
    tiers,
    rules,
    qualityDial: { default: defaultDial },
    frontierModel
  };
}

function parseTiers(value: unknown): Record<string, string[]> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Invalid routing config tiers");
  }

  const tiers: Record<string, string[]> = {};
  for (const [tier, models] of Object.entries(value)) {
    if (!Array.isArray(models) || models.some((model) => typeof model !== "string")) {
      throw new Error("Invalid routing config tier models");
    }
    tiers[tier] = models;
  }

  if (Object.keys(tiers).length === 0) {
    throw new Error("Invalid routing config tiers");
  }

  return tiers;
}

function parseRules(value: unknown): RoutingRule[] {
  if (!Array.isArray(value)) {
    throw new Error("Invalid routing config rules");
  }

  const rules: RoutingRule[] = [];
  for (const rawRule of value) {
    if (typeof rawRule !== "object" || rawRule === null || Array.isArray(rawRule)) {
      throw new Error("Invalid routing config rule");
    }

    const rule = rawRule as Record<string, unknown>;
    if (typeof rule.when !== "string" || typeof rule.tier !== "number") {
      throw new Error("Invalid routing config rule");
    }

    if (
      rule.when === "default" ||
      /^requestedModel contains '[^']+'$/.test(rule.when) ||
      /^promptTokens > \d+$/.test(rule.when)
    ) {
      rules.push({ when: rule.when as RoutingRule["when"], tier: rule.tier });
    } else {
      throw new Error("Invalid routing config rule condition");
    }
  }

  if (!rules.some((rule) => rule.when === "default")) {
    throw new Error("Routing config requires a default rule");
  }

  return rules;
}

function parseDefaultDial(value: unknown): number {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return 5;
  }

  const defaultDial = (value as Record<string, unknown>).default;
  return typeof defaultDial === "number" ? clamp(defaultDial, 0, 10) : 5;
}

function findBaseTier(model: string, promptTokens: number, rules: RoutingRule[]): number {
  for (const rule of rules) {
    if (rule.when === "default") {
      return rule.tier;
    }

    if (rule.when.startsWith("requestedModel contains ")) {
      const needle = rule.when.slice("requestedModel contains '".length, -1);
      if (model.includes(needle)) {
        return rule.tier;
      }
    }

    if (rule.when.startsWith("promptTokens > ")) {
      const threshold = Number.parseInt(rule.when.slice("promptTokens > ".length), 10);
      if (promptTokens > threshold) {
        return rule.tier;
      }
    }
  }

  throw new Error("Routing config requires a default rule");
}

function estimatePromptTokens(request: AnthropicMessagesRequest): number {
  const text = JSON.stringify({
    system: request.system,
    messages: request.messages,
    tools: request.tools
  });
  return Math.ceil(text.length / 4);
}

function readQualityDial(metadata: JsonObject | undefined, defaultDial: number): number {
  const value = metadata?.qualityDial;
  return typeof value === "number" ? clamp(value, 0, 10) : clamp(defaultDial, 0, 10);
}

function firstModelForTier(config: Pick<RoutingConfig, "tiers">, tier: number): string {
  const models = config.tiers[String(tier)];
  if (models === undefined || models[0] === undefined) {
    throw new Error(`Routing tier ${tier} has no models`);
  }
  return models[0];
}

function clampTier(tier: number, config: Pick<RoutingConfig, "tiers">): number {
  return clamp(tier, minTier(config.tiers), maxTier(config.tiers));
}

function minTier(tiers: Record<string, string[]>): number {
  return Math.min(...Object.keys(tiers).map(Number));
}

function maxTier(tiers: Record<string, string[]>): number {
  return Math.max(...Object.keys(tiers).map(Number));
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}
