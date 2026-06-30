import type {
  AnthropicContentBlock,
  AnthropicMessageParam,
  AnthropicMessageResponse,
  AnthropicMessagesRequest,
  AnthropicStopReason,
  AnthropicTextBlock,
  AnthropicTool,
  AnthropicToolChoice,
  AnthropicToolResultBlock,
  JsonObject,
  JsonValue,
  OpenAIChatCompletionRequest,
  OpenAIChatCompletionResponse,
  OpenAIMessage,
  OpenAITool,
  OpenAIToolCall,
  OpenAIToolChoice
} from "./types.js";

export type TranslationOptions = {
  model: string;
  maxCompletionTokens?: number;
};

export function toOpenAIRequest(
  request: AnthropicMessagesRequest,
  options: TranslationOptions
): OpenAIChatCompletionRequest {
  const messages: OpenAIMessage[] = [];
  const systemContent = systemToText(request.system);

  if (systemContent.length > 0) {
    messages.push({ role: "system", content: systemContent });
  }

  for (const message of request.messages) {
    messages.push(...toOpenAIMessages(message));
  }

  const translated: OpenAIChatCompletionRequest = {
    model: options.model,
    messages,
    max_tokens: clampMaxTokens(request.max_tokens, options.maxCompletionTokens),
    stream: request.stream ?? false
  };

  if (request.metadata !== undefined) {
    translated.metadata = request.metadata;
  }

  if (request.stop_sequences !== undefined && request.stop_sequences.length > 0) {
    translated.stop = request.stop_sequences;
  }

  if (request.stream === true) {
    translated.stream_options = { include_usage: true };
  }

  if (request.temperature !== undefined) {
    translated.temperature = request.temperature;
  }

  if (request.top_p !== undefined) {
    translated.top_p = request.top_p;
  }

  if (request.tools !== undefined && request.tools.length > 0) {
    translated.tools = request.tools.map(toOpenAITool);
  }

  if (request.tool_choice !== undefined) {
    translated.tool_choice = toOpenAIToolChoice(request.tool_choice);
  }

  return translated;
}

function clampMaxTokens(requested: number, limit: number | undefined): number {
  if (limit === undefined || limit <= 0) {
    return requested;
  }

  return Math.min(requested, Math.floor(limit));
}

export function fromOpenAIResponse(
  response: OpenAIChatCompletionResponse
): AnthropicMessageResponse {
  const choice = response.choices[0];
  const message = choice?.message;
  const content: AnthropicMessageResponse["content"] = [];

  if (message?.content !== undefined && message.content !== null && message.content.length > 0) {
    content.push({ type: "text", text: message.content });
  }

  for (const toolCall of message?.tool_calls ?? []) {
    content.push({
      type: "tool_use",
      id: toolCall.id,
      name: toolCall.function.name,
      input: parseToolArguments(toolCall.function.arguments)
    });
  }

  return {
    id: response.id.startsWith("msg_") ? response.id : `msg_${response.id}`,
    type: "message",
    role: "assistant",
    content,
    model: response.model,
    stop_reason: mapFinishReason(choice?.finish_reason ?? null),
    stop_sequence: null,
    usage: {
      input_tokens: response.usage?.prompt_tokens ?? 0,
      output_tokens: response.usage?.completion_tokens ?? 0
    }
  };
}

export function mapFinishReason(finishReason: string | null): AnthropicStopReason | null {
  switch (finishReason) {
    case null:
      return null;
    case "stop":
      return "end_turn";
    case "length":
      return "max_tokens";
    case "tool_calls":
    case "function_call":
      return "tool_use";
    default:
      return "end_turn";
  }
}

function toOpenAIMessages(message: AnthropicMessageParam): OpenAIMessage[] {
  if (typeof message.content === "string") {
    return [{ role: message.role, content: message.content }];
  }

  if (message.role === "assistant") {
    return [assistantBlocksToOpenAIMessage(message.content)];
  }

  return userBlocksToOpenAIMessages(message.content);
}

function assistantBlocksToOpenAIMessage(blocks: AnthropicContentBlock[]): OpenAIMessage {
  const text: string[] = [];
  const toolCalls: OpenAIToolCall[] = [];

  for (const block of blocks) {
    if (block.type === "text") {
      text.push(block.text);
    } else if (block.type === "tool_use") {
      toolCalls.push({
        id: block.id,
        type: "function",
        function: {
          name: block.name,
          arguments: JSON.stringify(block.input)
        }
      });
    }
  }

  const message: OpenAIMessage = {
    role: "assistant",
    content: text.length > 0 ? text.join("\n") : null
  };

  if (toolCalls.length > 0) {
    message.tool_calls = toolCalls;
  }

  return message;
}

function userBlocksToOpenAIMessages(blocks: AnthropicContentBlock[]): OpenAIMessage[] {
  const messages: OpenAIMessage[] = [];
  let textBuffer: string[] = [];

  const flushText = (): void => {
    if (textBuffer.length === 0) {
      return;
    }

    messages.push({ role: "user", content: textBuffer.join("\n") });
    textBuffer = [];
  };

  for (const block of blocks) {
    if (block.type === "text") {
      textBuffer.push(block.text);
    } else if (block.type === "tool_result") {
      flushText();
      messages.push({
        role: "tool",
        tool_call_id: block.tool_use_id,
        content: toolResultToText(block)
      });
    }
  }

  flushText();
  return messages;
}

function toOpenAITool(tool: AnthropicTool): OpenAITool {
  const translated: OpenAITool = {
    type: "function",
    function: {
      name: tool.name,
      parameters: tool.input_schema
    }
  };

  if (tool.description !== undefined) {
    translated.function.description = tool.description;
  }

  return translated;
}

function toOpenAIToolChoice(toolChoice: AnthropicToolChoice): OpenAIToolChoice {
  switch (toolChoice.type) {
    case "auto":
      return "auto";
    case "any":
      return "required";
    case "tool":
      return {
        type: "function",
        function: {
          name: toolChoice.name
        }
      };
  }
}

function systemToText(system: AnthropicMessagesRequest["system"]): string {
  if (system === undefined) {
    return "";
  }

  if (typeof system === "string") {
    return system;
  }

  return system.map((block: AnthropicTextBlock) => block.text).join("\n");
}

function toolResultToText(block: AnthropicToolResultBlock): string {
  if (block.content === undefined) {
    return block.is_error === true ? "[tool error]" : "";
  }

  if (typeof block.content === "string") {
    return block.is_error === true ? `[tool error]\n${block.content}` : block.content;
  }

  const text = block.content.map((contentBlock) => contentBlock.text).join("\n");
  return block.is_error === true ? `[tool error]\n${text}` : text;
}

function parseToolArguments(argumentsJson: string): JsonObject {
  try {
    const parsed: unknown = JSON.parse(argumentsJson.length > 0 ? argumentsJson : "{}");
    return isJsonObject(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function isJsonObject(value: unknown): value is JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }

  return Object.values(value).every(isJsonValue);
}

function isJsonValue(value: unknown): value is JsonValue {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return true;
  }

  if (Array.isArray(value)) {
    return value.every(isJsonValue);
  }

  return isJsonObject(value);
}
