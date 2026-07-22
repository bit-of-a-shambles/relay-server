import { randomUUID } from "node:crypto";
import type {
  AnthropicMessageResponse,
  OpenAIChatCompletionChunk,
  OpenAIToolCall
} from "./types.js";
import { mapFinishReason } from "./translate.js";

type SseMessage = {
  event?: string;
  data: string;
};

type OpenToolBlock = {
  contentIndex: number;
  id: string;
  name: string;
  argumentsJson: string;
  stopped: boolean;
};

type OpenAIToolCallDelta = {
  index?: number;
  id?: string;
  type?: "function";
  function?: {
    name?: string;
    arguments?: string;
  };
};

type StreamState = {
  messageStarted: boolean;
  messageId: string;
  model: string;
  nextContentIndex: number;
  textBlockOpen: boolean;
  toolBlocks: Map<number, OpenToolBlock>;
  finishReason: string | null;
  promptTokens: number;
  completionTokens: number;
  costUsd: number | null;
};

export type StreamSummary = {
  model: string;
  promptTokens: number;
  completionTokens: number;
  costUsd: number | null;
};

export async function* openAIStreamToAnthropicSse(
  stream: ReadableStream<Uint8Array>,
  fallbackModel: string,
  onComplete?: (summary: StreamSummary) => void
): AsyncGenerator<string> {
  const state: StreamState = {
    messageStarted: false,
    messageId: `msg_${randomUUID()}`,
    model: fallbackModel,
    nextContentIndex: 0,
    textBlockOpen: false,
    toolBlocks: new Map<number, OpenToolBlock>(),
    finishReason: null,
    promptTokens: 0,
    completionTokens: 0,
    costUsd: null
  };

  for await (const message of parseSse(stream)) {
    if (message.data === "[DONE]") {
      break;
    }

    const chunk = parseChunk(message.data);
    if (chunk === null) {
      continue;
    }

    if (chunk.id !== undefined) {
      state.messageId = chunk.id.startsWith("msg_") ? chunk.id : `msg_${chunk.id}`;
    }

    if (chunk.model !== undefined) {
      state.model = chunk.model;
    }

    yield* ensureMessageStarted(state);
    updateUsage(state, chunk);

    for (const choice of chunk.choices ?? []) {
      if (choice.finish_reason !== undefined && choice.finish_reason !== null) {
        state.finishReason = choice.finish_reason;
      }

      const delta = choice.delta;
      if (delta === undefined) {
        continue;
      }

      const text = delta.content;
      if (text !== undefined && text !== null && text.length > 0) {
        yield* emitTextDelta(state, text);
      }

      for (const toolCallDelta of delta.tool_calls ?? []) {
        yield* emitToolDelta(state, toolCallDelta);
      }
    }
  }

  onComplete?.({
    model: state.model,
    promptTokens: state.promptTokens,
    completionTokens: state.completionTokens,
    costUsd: state.costUsd
  });

  yield* stopOpenBlocks(state);
  yield sse("message_delta", {
    type: "message_delta",
    delta: {
      stop_reason: mapFinishReason(state.finishReason),
      stop_sequence: null
    },
    usage: {
      output_tokens: state.completionTokens
    }
  });
  yield sse("message_stop", { type: "message_stop" });
}

export async function collectText(stream: ReadableStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let output = "";

  for await (const chunk of readStream(stream)) {
    output += decoder.decode(chunk, { stream: true });
  }

  output += decoder.decode();
  return output;
}

export function sse(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

async function* parseSse(stream: ReadableStream<Uint8Array>): AsyncGenerator<SseMessage> {
  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of readStream(stream)) {
    buffer += decoder.decode(chunk, { stream: true });

    let separatorIndex = findSseSeparator(buffer);
    while (separatorIndex !== -1) {
      const rawEvent = buffer.slice(0, separatorIndex);
      buffer = buffer.slice(separatorIndex + separatorLength(buffer, separatorIndex));
      const parsed = parseSseEvent(rawEvent);

      if (parsed !== null) {
        yield parsed;
      }

      separatorIndex = findSseSeparator(buffer);
    }
  }

  buffer += decoder.decode();

  if (buffer.trim().length > 0) {
    const parsed = parseSseEvent(buffer);
    if (parsed !== null) {
      yield parsed;
    }
  }
}

async function* readStream(stream: ReadableStream<Uint8Array>): AsyncGenerator<Uint8Array> {
  const reader = stream.getReader();

  try {
    while (true) {
      const result = await reader.read();
      if (result.done) {
        return;
      }

      yield result.value;
    }
  } finally {
    reader.releaseLock();
  }
}

function parseSseEvent(rawEvent: string): SseMessage | null {
  const data: string[] = [];
  let event: string | undefined;

  for (const line of rawEvent.split(/\r?\n/)) {
    if (line.length === 0 || line.startsWith(":")) {
      continue;
    }

    if (line.startsWith("event:")) {
      event = line.slice("event:".length).trimStart();
    } else if (line.startsWith("data:")) {
      data.push(line.slice("data:".length).trimStart());
    }
  }

  if (data.length === 0) {
    return null;
  }

  const message: SseMessage = { data: data.join("\n") };
  if (event !== undefined) {
    message.event = event;
  }

  return message;
}

function findSseSeparator(buffer: string): number {
  const lf = buffer.indexOf("\n\n");
  const crlf = buffer.indexOf("\r\n\r\n");

  if (lf === -1) {
    return crlf;
  }

  if (crlf === -1) {
    return lf;
  }

  return Math.min(lf, crlf);
}

function separatorLength(buffer: string, index: number): number {
  return buffer.slice(index, index + 4) === "\r\n\r\n" ? 4 : 2;
}

function parseChunk(data: string): OpenAIChatCompletionChunk | null {
  try {
    const parsed: unknown = JSON.parse(data);
    return isChunk(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function isChunk(value: unknown): value is OpenAIChatCompletionChunk {
  return typeof value === "object" && value !== null;
}

function updateUsage(state: StreamState, chunk: OpenAIChatCompletionChunk): void {
  if (chunk.usage === undefined || chunk.usage === null) {
    return;
  }

  state.promptTokens = chunk.usage.prompt_tokens ?? state.promptTokens;
  state.completionTokens = chunk.usage.completion_tokens ?? state.completionTokens;
  state.costUsd = chunk.usage.cost ?? state.costUsd;
}

function* ensureMessageStarted(state: StreamState): Generator<string> {
  if (state.messageStarted) {
    return;
  }

  state.messageStarted = true;
  const message: AnthropicMessageResponse = {
    id: state.messageId,
    type: "message",
    role: "assistant",
    content: [],
    model: state.model,
    stop_reason: null,
    stop_sequence: null,
    usage: {
      input_tokens: state.promptTokens,
      output_tokens: 0
    }
  };
  yield sse("message_start", { type: "message_start", message });
}

function* emitTextDelta(state: StreamState, text: string): Generator<string> {
  if (hasOpenToolBlocks(state)) {
    yield* stopOpenToolBlocks(state);
  }

  if (!state.textBlockOpen) {
    const index = state.nextContentIndex;
    state.nextContentIndex += 1;
    state.textBlockOpen = true;
    yield sse("content_block_start", {
      type: "content_block_start",
      index,
      content_block: { type: "text", text: "" }
    });
  }

  yield sse("content_block_delta", {
    type: "content_block_delta",
    index: state.nextContentIndex - 1,
    delta: { type: "text_delta", text }
  });
}

function* emitToolDelta(
  state: StreamState,
  toolCallDelta: OpenAIToolCallDelta
): Generator<string> {
  if (state.textBlockOpen) {
    yield sse("content_block_stop", {
      type: "content_block_stop",
      index: state.nextContentIndex - 1
    });
    state.textBlockOpen = false;
  }

  const openAIIndex = toolCallDelta.index ?? 0;
  let block = state.toolBlocks.get(openAIIndex);

  if (block === undefined) {
    block = {
      contentIndex: state.nextContentIndex,
      id: toolCallDelta.id ?? `call_${randomUUID()}`,
      name: toolCallDelta.function?.name ?? "unknown_tool",
      argumentsJson: "",
      stopped: false
    };
    state.nextContentIndex += 1;
    state.toolBlocks.set(openAIIndex, block);
    yield sse("content_block_start", {
      type: "content_block_start",
      index: block.contentIndex,
      content_block: {
        type: "tool_use",
        id: block.id,
        name: block.name,
        input: {}
      }
    });
  }

  if (toolCallDelta.id !== undefined) {
    block.id = toolCallDelta.id;
  }

  if (toolCallDelta.function?.name !== undefined) {
    block.name = toolCallDelta.function.name;
  }

  const argumentDelta = toolCallDelta.function?.arguments;
  if (argumentDelta !== undefined && argumentDelta.length > 0) {
    block.argumentsJson += argumentDelta;
    yield sse("content_block_delta", {
      type: "content_block_delta",
      index: block.contentIndex,
      delta: { type: "input_json_delta", partial_json: argumentDelta }
    });
  }
}

function* stopOpenBlocks(state: StreamState): Generator<string> {
  if (state.textBlockOpen) {
    yield sse("content_block_stop", {
      type: "content_block_stop",
      index: state.nextContentIndex - 1
    });
    state.textBlockOpen = false;
  }

  yield* stopOpenToolBlocks(state);
}

function* stopOpenToolBlocks(state: StreamState): Generator<string> {
  const blocks = [...state.toolBlocks.values()].sort((left, right) => {
    return left.contentIndex - right.contentIndex;
  });

  for (const block of blocks) {
    if (block.stopped) {
      continue;
    }

    yield sse("content_block_stop", {
      type: "content_block_stop",
      index: block.contentIndex
    });
    block.stopped = true;
  }
}

function hasOpenToolBlocks(state: StreamState): boolean {
  return [...state.toolBlocks.values()].some((block) => !block.stopped);
}
