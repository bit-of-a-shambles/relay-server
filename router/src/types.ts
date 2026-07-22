export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
export type JsonObject = { [key: string]: JsonValue };

export type AnthropicRole = "user" | "assistant";

export type AnthropicTextBlock = {
  type: "text";
  text: string;
};

export type AnthropicToolUseBlock = {
  type: "tool_use";
  id: string;
  name: string;
  input: JsonObject;
};

export type AnthropicToolResultBlock = {
  type: "tool_result";
  tool_use_id: string;
  content?: string | AnthropicTextBlock[];
  is_error?: boolean;
};

export type AnthropicContentBlock =
  | AnthropicTextBlock
  | AnthropicToolUseBlock
  | AnthropicToolResultBlock;

export type AnthropicMessageParam = {
  role: AnthropicRole;
  content: string | AnthropicContentBlock[];
};

export type AnthropicTool = {
  name: string;
  description?: string;
  input_schema: JsonObject;
};

export type AnthropicToolChoice =
  | { type: "auto" }
  | { type: "any" }
  | { type: "tool"; name: string };

export type AnthropicMessagesRequest = {
  model: string;
  max_tokens: number;
  messages: AnthropicMessageParam[];
  system?: string | AnthropicTextBlock[];
  metadata?: JsonObject;
  stop_sequences?: string[];
  stream?: boolean;
  temperature?: number;
  tools?: AnthropicTool[];
  tool_choice?: AnthropicToolChoice;
  top_p?: number;
};

export type AnthropicStopReason =
  | "end_turn"
  | "max_tokens"
  | "stop_sequence"
  | "tool_use";

export type AnthropicMessageResponse = {
  id: string;
  type: "message";
  role: "assistant";
  content: (AnthropicTextBlock | AnthropicToolUseBlock)[];
  model: string;
  stop_reason: AnthropicStopReason | null;
  stop_sequence: string | null;
  usage: {
    input_tokens: number;
    output_tokens: number;
  };
};

export type OpenAIRole = "system" | "user" | "assistant" | "tool";

export type OpenAIToolCall = {
  id: string;
  type: "function";
  function: {
    name: string;
    arguments: string;
  };
};

export type OpenAIMessage = {
  role: OpenAIRole;
  content?: string | null;
  tool_call_id?: string;
  tool_calls?: OpenAIToolCall[];
};

export type OpenAITool = {
  type: "function";
  function: {
    name: string;
    description?: string;
    parameters: JsonObject;
  };
};

export type OpenAIToolChoice =
  | "auto"
  | "required"
  | {
      type: "function";
      function: {
        name: string;
      };
    };

export type OpenAIChatCompletionRequest = {
  model: string;
  session_id?: string;
  messages: OpenAIMessage[];
  max_tokens?: number;
  metadata?: JsonObject;
  stop?: string[];
  stream?: boolean;
  stream_options?: {
    include_usage: boolean;
  };
  temperature?: number;
  tool_choice?: OpenAIToolChoice;
  tools?: OpenAITool[];
  top_p?: number;
};

export type OpenAIChatCompletionResponse = {
  id: string;
  model: string;
  choices: {
    index: number;
    finish_reason: string | null;
    message: {
      role: "assistant";
      content?: string | null;
      tool_calls?: OpenAIToolCall[];
    };
  }[];
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
};

export type OpenAIChatCompletionChunk = {
  id?: string;
  model?: string;
  choices?: {
    index: number;
    finish_reason?: string | null;
    delta?: {
      role?: "assistant";
      content?: string | null;
      tool_calls?: {
        index?: number;
        id?: string;
        type?: "function";
        function?: {
          name?: string;
          arguments?: string;
        };
      }[];
    };
  }[];
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
    cost?: number;
  } | null;
};
