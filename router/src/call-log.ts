import { appendFileSync } from "node:fs";

export type LlmCallRecord = {
  requestedModel: string;
  routedModel: string;
  tier: number;
  promptTokens: number;
  completionTokens: number;
  costUsd: number | null;
  frontierCostUsd: number;
  latencyMs: number;
  escalationReason: string | null;
  status: "success" | "error";
  errorMessage: string | null;
  createdAt: string;
};

export type CallLogSink = {
  record: (record: LlmCallRecord) => void | Promise<void>;
};

export class MemoryCallLogSink implements CallLogSink {
  readonly records: LlmCallRecord[] = [];

  record(record: LlmCallRecord): void {
    this.records.push(record);
  }
}

export class JsonlCallLogSink implements CallLogSink {
  constructor(private readonly path: string) {}

  record(record: LlmCallRecord): void {
    appendFileSync(this.path, `${JSON.stringify(record)}\n`, "utf8");
  }
}

export function createCallLogSink(path: string | undefined): CallLogSink | undefined {
  if (path === undefined || path.length === 0) {
    return undefined;
  }

  return new JsonlCallLogSink(path);
}
