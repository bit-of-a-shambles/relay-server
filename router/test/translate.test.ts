import { describe, expect, it } from "vitest";
import { fromOpenAIResponse, mapFinishReason, toOpenAIRequest } from "../src/translate.js";
import type { AnthropicMessagesRequest, OpenAIChatCompletionResponse } from "../src/types.js";

describe("Anthropic to OpenAI translation", () => {
  it("maps text, tools, tool use, and tool results", () => {
    const request: AnthropicMessagesRequest = {
      model: "claude-sonnet-4-5",
      max_tokens: 1024,
      system: "You are concise.",
      stream: true,
      temperature: 0.2,
      tools: [
        {
          name: "read_file",
          description: "Read a file",
          input_schema: {
            type: "object",
            properties: {
              path: { type: "string" }
            },
            required: ["path"]
          }
        }
      ],
      tool_choice: { type: "auto" },
      messages: [
        { role: "user", content: "Inspect README.md" },
        {
          role: "assistant",
          content: [
            { type: "text", text: "I will inspect it." },
            {
              type: "tool_use",
              id: "toolu_1",
              name: "read_file",
              input: { path: "README.md" }
            }
          ]
        },
        {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: "toolu_1",
              content: "Relay docs"
            },
            { type: "text", text: "Summarize it." }
          ]
        }
      ]
    };

    const translated = toOpenAIRequest(request, { model: "openai/gpt-5.5" });

    expect(translated).toMatchObject({
      model: "openai/gpt-5.5",
      max_tokens: 1024,
      stream: true,
      stream_options: { include_usage: true },
      temperature: 0.2,
      tool_choice: "auto",
      tools: [
        {
          type: "function",
          function: {
            name: "read_file",
            description: "Read a file",
            parameters: {
              type: "object",
              properties: {
                path: { type: "string" }
              },
              required: ["path"]
            }
          }
        }
      ],
      messages: [
        { role: "system", content: "You are concise." },
        { role: "user", content: "Inspect README.md" },
        {
          role: "assistant",
          content: "I will inspect it.",
          tool_calls: [
            {
              id: "toolu_1",
              type: "function",
              function: {
                name: "read_file",
                arguments: "{\"path\":\"README.md\"}"
              }
            }
          ]
        },
        { role: "tool", tool_call_id: "toolu_1", content: "Relay docs" },
        { role: "user", content: "Summarize it." }
      ]
    });
  });

  it("maps optional controls and non-string system blocks", () => {
    const request: AnthropicMessagesRequest = {
      model: "claude-sonnet-4-5",
      max_tokens: 64,
      system: [
        { type: "text", text: "First system block." },
        { type: "text", text: "Second system block." }
      ],
      metadata: { sessionId: "session_1" },
      stop_sequences: ["STOP"],
      top_p: 0.8,
      tool_choice: { type: "tool", name: "read_file" },
      tools: [
        {
          name: "read_file",
          input_schema: { type: "object" }
        }
      ],
      messages: [
        {
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: "toolu_2",
              name: "read_file",
              input: { path: "README.md" }
            }
          ]
        }
      ]
    };

    expect(toOpenAIRequest(request, { model: "openrouter/test" })).toMatchObject({
      model: "openrouter/test",
      metadata: { sessionId: "session_1" },
      stop: ["STOP"],
      top_p: 0.8,
      tool_choice: {
        type: "function",
        function: { name: "read_file" }
      },
      tools: [
        {
          type: "function",
          function: {
            name: "read_file",
            parameters: { type: "object" }
          }
        }
      ],
      messages: [
        { role: "system", content: "First system block.\nSecond system block." },
        {
          role: "assistant",
          content: null,
          tool_calls: [
            {
              id: "toolu_2",
              type: "function",
              function: {
                name: "read_file",
                arguments: "{\"path\":\"README.md\"}"
              }
            }
          ]
        }
      ],
      stream: false
    });
  });

  it("caps max tokens when a completion budget limit is configured", () => {
    const request: AnthropicMessagesRequest = {
      model: "claude-sonnet-4-5",
      max_tokens: 64_000,
      messages: [{ role: "user", content: "Say hello" }]
    };

    expect(toOpenAIRequest(request, { model: "openai/gpt-5.5", maxCompletionTokens: 4096 }).max_tokens)
      .toBe(4096);
    expect(toOpenAIRequest(request, { model: "openai/gpt-5.5" }).max_tokens).toBe(64_000);
  });

  it("maps tool choice any and tool result error content shapes", () => {
    const baseRequest = {
      model: "claude-sonnet-4-5",
      max_tokens: 64,
      tool_choice: { type: "any" as const },
      messages: [
        {
          role: "user" as const,
          content: [
            {
              type: "tool_result" as const,
              tool_use_id: "toolu_empty",
              is_error: true
            },
            {
              type: "tool_result" as const,
              tool_use_id: "toolu_text_error",
              content: "failed",
              is_error: true
            },
            {
              type: "tool_result" as const,
              tool_use_id: "toolu_blocks",
              content: [
                { type: "text" as const, text: "line 1" },
                { type: "text" as const, text: "line 2" }
              ]
            },
            {
              type: "tool_result" as const,
              tool_use_id: "toolu_block_error",
              content: [{ type: "text" as const, text: "bad block" }],
              is_error: true
            }
          ]
        }
      ]
    };

    expect(toOpenAIRequest(baseRequest, { model: "openrouter/test" })).toMatchObject({
      tool_choice: "required",
      messages: [
        { role: "tool", tool_call_id: "toolu_empty", content: "[tool error]" },
        { role: "tool", tool_call_id: "toolu_text_error", content: "[tool error]\nfailed" },
        { role: "tool", tool_call_id: "toolu_blocks", content: "line 1\nline 2" },
        { role: "tool", tool_call_id: "toolu_block_error", content: "[tool error]\nbad block" }
      ]
    });
  });

  it("maps text-only content arrays and empty tool results", () => {
    const request: AnthropicMessagesRequest = {
      model: "claude-sonnet-4-5",
      max_tokens: 64,
      messages: [
        {
          role: "assistant",
          content: [{ type: "text", text: "Only text" }]
        },
        {
          role: "assistant",
          content: [
            { type: "tool_result", tool_use_id: "ignored", content: "ignored" } as never
          ]
        },
        {
          role: "user",
          content: [{ type: "text", text: "Array text" }]
        },
        {
          role: "user",
          content: [{ type: "tool_result", tool_use_id: "toolu_empty_ok" }]
        },
        {
          role: "user",
          content: [
            { type: "tool_use", id: "ignored", name: "ignored", input: {} } as never
          ]
        }
      ]
    };

    expect(toOpenAIRequest(request, { model: "openrouter/test" }).messages).toEqual([
      { role: "assistant", content: "Only text" },
      { role: "assistant", content: null },
      { role: "user", content: "Array text" },
      { role: "tool", tool_call_id: "toolu_empty_ok", content: "" }
    ]);
  });
});

describe("OpenAI to Anthropic translation", () => {
  it("maps assistant text and function calls back to content blocks", () => {
    const response: OpenAIChatCompletionResponse = {
      id: "chatcmpl_1",
      model: "openai/gpt-5.5",
      choices: [
        {
          index: 0,
          finish_reason: "tool_calls",
          message: {
            role: "assistant",
            content: "I need the file.",
            tool_calls: [
              {
                id: "call_1",
                type: "function",
                function: {
                  name: "read_file",
                  arguments: "{\"path\":\"README.md\"}"
                }
              }
            ]
          }
        }
      ],
      usage: {
        prompt_tokens: 50,
        completion_tokens: 12,
        total_tokens: 62
      }
    };

    expect(fromOpenAIResponse(response)).toEqual({
      id: "msg_chatcmpl_1",
      type: "message",
      role: "assistant",
      model: "openai/gpt-5.5",
      stop_reason: "tool_use",
      stop_sequence: null,
      usage: {
        input_tokens: 50,
        output_tokens: 12
      },
      content: [
        { type: "text", text: "I need the file." },
        {
          type: "tool_use",
          id: "call_1",
          name: "read_file",
          input: { path: "README.md" }
        }
      ]
    });
  });

  it("handles missing content, existing Anthropic ids, usage defaults, and malformed tool arguments", () => {
    const response: OpenAIChatCompletionResponse = {
      id: "msg_existing",
      model: "openrouter/test",
      choices: [
        {
          index: 0,
          finish_reason: "length",
          message: {
            role: "assistant",
            content: "",
            tool_calls: [
              {
                id: "call_empty",
                type: "function",
                function: { name: "empty_args", arguments: "" }
              },
              {
                id: "call_invalid_json",
                type: "function",
                function: { name: "invalid_json", arguments: "{" }
              },
              {
                id: "call_array",
                type: "function",
                function: { name: "array_args", arguments: "[]" }
              },
              {
                id: "call_nested",
                type: "function",
                function: {
                  name: "nested_args",
                  arguments: "{\"ok\":true,\"items\":[{\"n\":1},null]}"
                }
              }
            ]
          }
        }
      ]
    };

    expect(fromOpenAIResponse(response)).toEqual({
      id: "msg_existing",
      type: "message",
      role: "assistant",
      content: [
        { type: "tool_use", id: "call_empty", name: "empty_args", input: {} },
        { type: "tool_use", id: "call_invalid_json", name: "invalid_json", input: {} },
        { type: "tool_use", id: "call_array", name: "array_args", input: {} },
        {
          type: "tool_use",
          id: "call_nested",
          name: "nested_args",
          input: { ok: true, items: [{ n: 1 }, null] }
        }
      ],
      model: "openrouter/test",
      stop_reason: "max_tokens",
      stop_sequence: null,
      usage: {
        input_tokens: 0,
        output_tokens: 0
      }
    });
  });

  it("handles empty choices", () => {
    expect(
      fromOpenAIResponse({
        id: "chatcmpl_empty",
        model: "openrouter/test",
        choices: []
      })
    ).toMatchObject({
      id: "msg_chatcmpl_empty",
      content: [],
      stop_reason: null,
      usage: {
        input_tokens: 0,
        output_tokens: 0
      }
    });
  });

  it("maps all known and fallback finish reasons", () => {
    expect(mapFinishReason(null)).toBeNull();
    expect(mapFinishReason("stop")).toBe("end_turn");
    expect(mapFinishReason("length")).toBe("max_tokens");
    expect(mapFinishReason("tool_calls")).toBe("tool_use");
    expect(mapFinishReason("function_call")).toBe("tool_use");
    expect(mapFinishReason("content_filter")).toBe("end_turn");
  });
});
