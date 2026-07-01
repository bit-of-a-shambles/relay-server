import { appendFileSync } from "node:fs";

export type LlmCallRecord = {
  taskId: string | null;
  sessionId: string | null;
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

export class HttpCallLogSink implements CallLogSink {
  constructor(
    private readonly url: string,
    private readonly token: string,
    private readonly fetchImpl: typeof fetch = fetch
  ) {}

  async record(record: LlmCallRecord): Promise<void> {
    try {
      await this.fetchImpl(this.url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.token}`
        },
        body: JSON.stringify(record)
      });
    } catch (error: unknown) {
      console.error(
        "[relay-router] failed to post call record to daemon:",
        error instanceof Error ? error.message : String(error)
      );
    }
  }
}

export class FanOutCallLogSink implements CallLogSink {
  constructor(private readonly sinks: CallLogSink[]) {}

  async record(record: LlmCallRecord): Promise<void> {
    for (const sink of this.sinks) {
      await sink.record(record);
    }
  }
}

export type CreateSinkOptions = {
  jsonlPath?: string | undefined;
  httpUrl?: string | undefined;
  httpToken?: string | undefined;
  fetchImpl?: typeof fetch | undefined;
};

export function createCallLogSink(path: string | undefined): CallLogSink | undefined;
export function createCallLogSink(options: CreateSinkOptions): CallLogSink | undefined;
export function createCallLogSink(
  arg: string | undefined | CreateSinkOptions
): CallLogSink | undefined {
  if (typeof arg === "string" || arg === undefined) {
    const path = arg;
    if (path === undefined || path.length === 0) {
      return undefined;
    }
    return new JsonlCallLogSink(path);
  }

  const { jsonlPath, httpUrl, httpToken, fetchImpl } = arg;
  const sinks: CallLogSink[] = [];

  if (jsonlPath !== undefined && jsonlPath.length > 0) {
    sinks.push(new JsonlCallLogSink(jsonlPath));
  }
  if (httpUrl !== undefined && httpUrl.length > 0) {
    sinks.push(new HttpCallLogSink(httpUrl, httpToken ?? "", fetchImpl));
  }

  if (sinks.length === 0) return undefined;
  if (sinks.length === 1) return sinks[0];
  return new FanOutCallLogSink(sinks);
}
