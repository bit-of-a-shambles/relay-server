import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

export type CapturedRequest = {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: string;
};

export type TestHttpServer = {
  baseUrl: string;
  close: () => Promise<void>;
  requests: CapturedRequest[];
};

export async function createTestServer(
  handler: (
    request: IncomingMessage,
    response: ServerResponse,
    body: string
  ) => void | Promise<void>
): Promise<TestHttpServer> {
  const requests: CapturedRequest[] = [];
  const server = createServer(async (request, response) => {
    const body = await readBody(request);
    requests.push({
      method: request.method ?? "",
      url: request.url ?? "",
      headers: request.headers,
      body
    });
    await handler(request, response, body);
  });

  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("Expected TCP test server address");
  }

  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    requests,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error !== undefined) {
            reject(error);
            return;
          }

          resolve();
        });
      })
  };
}

export function streamFromString(input: string): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(input));
      controller.close();
    }
  });
}

export async function collectAsync<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const values: T[] = [];

  for await (const value of iterable) {
    values.push(value);
  }

  return values;
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];

  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  return Buffer.concat(chunks).toString("utf8");
}
