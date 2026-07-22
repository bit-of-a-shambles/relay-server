import { describe, expect, it } from "vitest";
import { collectText, openAIStreamToAnthropicSse, sse } from "../src/sse.js";
import { collectAsync, streamFromString } from "./helpers.js";

describe("OpenAI SSE to Anthropic SSE translation", () => {
  it("streams text as Anthropic content block events", async () => {
    const upstream = [
      'data: {"id":"chatcmpl_1","model":"openrouter/test","choices":[{"index":0,"delta":{"role":"assistant"}}]}',
      'data: {"choices":[{"index":0,"delta":{"content":"Hello"}}]}',
      'data: {"choices":[{"index":0,"delta":{"content":" world"}}]}',
      'data: {"choices":[{"index":0,"finish_reason":"stop","delta":{}}],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"cost":0.002}}',
      "data: [DONE]",
      ""
    ].join("\n\n");

    const events: string[] = [];
    let summary: unknown;
    for await (const event of openAIStreamToAnthropicSse(
      streamFromString(upstream),
      "fallback/model",
      (value) => { summary = value; }
    )) {
      events.push(event);
    }

    const output = events.join("");
    expect(output).toContain("event: message_start");
    expect(output).toContain('"model":"openrouter/test"');
    expect(output).toContain('"type":"text_delta","text":"Hello"');
    expect(output).toContain('"type":"text_delta","text":" world"');
    expect(output).toContain('"stop_reason":"end_turn"');
    expect(output).toContain('"output_tokens":3');
    expect(output).toContain("event: message_stop");
    expect(summary).toEqual({
      model: "openrouter/test",
      promptTokens: 7,
      completionTokens: 3,
      costUsd: 0.002
    });
  });

  it("streams tool calls as Anthropic tool_use blocks", async () => {
    const upstream = [
      'data: {"id":"chatcmpl_2","model":"openrouter/test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}',
      'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]}}]}',
      'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"README.md\\"}"}}]}}]}',
      'data: {"choices":[{"index":0,"finish_reason":"tool_calls","delta":{}}],"usage":{"prompt_tokens":9,"completion_tokens":5,"total_tokens":14}}',
      "data: [DONE]",
      ""
    ].join("\n\n");

    const events: string[] = [];
    for await (const event of openAIStreamToAnthropicSse(
      streamFromString(upstream),
      "fallback/model"
    )) {
      events.push(event);
    }

    const output = events.join("");
    expect(output).toContain("event: content_block_start");
    expect(output).toContain('"type":"tool_use"');
    expect(output).toContain('"id":"call_1"');
    expect(output).toContain('"name":"read_file"');
    expect(output).toContain('"type":"input_json_delta","partial_json":"{\\"path\\":"');
    expect(output).toContain('"type":"input_json_delta","partial_json":"\\"README.md\\"}"');
    expect(output).toContain('"stop_reason":"tool_use"');
  });

  it("handles CRLF events, comments, malformed chunks, fallback model, and terminal buffers", async () => {
    const upstream = [
      ": keepalive\r\nevent: ignored\r\ndata: not-json",
      "data: 1",
      "data: {\"id\":\"chatcmpl_without_choices\"}",
      "data: {\"choices\":[{\"index\":0}]}",
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":null}}]}",
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"}}]}",
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Tail\"}}]}",
      "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"length\",\"delta\":{}}],\"usage\":null}",
      "data: [DONE]",
      ""
    ].join("\r\n\r\n");

    const output = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString(upstream), "fallback/model")
    )).join("");

    expect(output).toContain('"model":"fallback/model"');
    expect(output).toContain('"type":"text_delta","text":"Tail"');
    expect(output).toContain('"stop_reason":"max_tokens"');
  });

  it("parses terminal events without a final separator and ignores events without data", async () => {
    const noFinalSeparator = 'event: final\ndata: {"choices":[{"index":0,"delta":{"content":"Final"}}]}';
    const output = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString(noFinalSeparator), "fallback/model")
    )).join("");

    expect(output).toContain('"type":"text_delta","text":"Final"');

    const noDataOutput = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString("event: empty"), "fallback/model")
    )).join("");

    expect(noDataOutput).toContain("event: message_delta");
    expect(noDataOutput).not.toContain("event: message_start");

    const emptyOutput = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString(""), "fallback/model")
    )).join("");
    expect(emptyOutput).toContain("event: message_delta");
  });

  it("handles multiple separators and sorts multiple tool blocks before stopping them", async () => {
    const upstream = [
      'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_2","type":"function","function":{"name":"second","arguments":"{}"}},{"index":0,"id":"call_1","type":"function","function":{"name":"first","arguments":"{}"}}]}}]}',
      'data: {"choices":[{"index":0,"finish_reason":"tool_calls","delta":{}}]}',
      "data: [DONE]",
      ""
    ].join("\n\nextra: ignored\r\n\r\n");

    const output = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString(upstream), "fallback/model")
    )).join("");

    expect(output.indexOf('"name":"second"')).toBeLessThan(output.indexOf('"name":"first"'));
    expect(output).toContain('"stop_reason":"tool_use"');
  });

  it("keeps previous usage values and defaults missing tool call identity", async () => {
    const upstream = [
      'data: {"id":"chatcmpl_defaults","model":"openrouter/test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}],"usage":{"prompt_tokens":8,"completion_tokens":2}}',
      'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}],"usage":{"total_tokens":10}}',
      'data: {"choices":[{"index":0,"finish_reason":"tool_calls","delta":{}}]}',
      "data: [DONE]",
      ""
    ].join("\n\n");

    const output = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString(upstream), "fallback/model")
    )).join("");

    expect(output).toContain('"name":"unknown_tool"');
    expect(output).toContain('"output_tokens":2');
  });

  it("closes text before tool blocks and tool blocks before following text", async () => {
    const upstream = [
      'data: {"id":"msg_already","model":"openrouter/test","choices":[{"index":0,"delta":{"content":"Before"}}]}',
      'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_default","type":"function","function":{"arguments":"{}"}}]}}]}',
      'data: {"choices":[{"index":0,"delta":{"content":"After"}}]}',
      'data: {"choices":[{"index":0,"finish_reason":"stop","delta":{}}],"usage":{"completion_tokens":4}}',
      "data: [DONE]",
      ""
    ].join("\n\n");

    const output = (await collectAsync(
      openAIStreamToAnthropicSse(streamFromString(upstream), "fallback/model")
    )).join("");

    expect(output).toContain('"id":"msg_already"');
    expect(output).toContain('"name":"unknown_tool"');
    expect(output.indexOf('"text":"Before"')).toBeLessThan(output.indexOf('"type":"tool_use"'));
    expect(output.indexOf('"type":"tool_use"')).toBeLessThan(output.indexOf('"text":"After"'));
    expect(output).toContain('"output_tokens":4');
  });

  it("collects raw stream text and formats SSE events", async () => {
    await expect(collectText(streamFromString("hello"))).resolves.toBe("hello");
    expect(sse("ping", { type: "ping" })).toBe('event: ping\ndata: {"type":"ping"}\n\n');
  });
});
