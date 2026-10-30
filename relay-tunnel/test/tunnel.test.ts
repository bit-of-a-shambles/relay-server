import { readFileSync } from "node:fs";
import { beforeEach, afterEach, describe, it, expect, vi } from "vitest";
import worker, { TunnelRoom, digest, route, validFrame } from "../src/index";

class Socket {
  state: any; sent: any[] = []; closed: any[] = [];
  serializeAttachment(v: any) { this.state = structuredClone(v); }
  deserializeAttachment() { return structuredClone(this.state); }
  send(v: any) { this.sent.push(v); }
  close(...args: any[]) { this.closed.push(args); }
}
class Result {
  status: number; webSocket: any; body: any;
  constructor(body: any, init: any = {}) { this.body = body; this.status = init.status ?? 200; this.webSocket = init.webSocket; }
  static json(value: any, init?: any) { return new Result(JSON.stringify(value), init); }
  async json() { return JSON.parse(this.body); }
}
class Context {
  sockets: { socket: Socket; tags: string[] }[] = [];
  getWebSockets(tag: string) { return this.sockets.filter(v => v.tags.includes(tag)).map(v => v.socket); }
  acceptWebSocket(socket: Socket, tags: string[]) { this.sockets.push({ socket, tags }); }
}
const host = "a".repeat(64), phone = "b".repeat(64);
let room: string, phoneHash: string;
function request(role: string, token: string = role === "host" ? host : phone, headers: any = {}, suffix = "") {
  return new Request(`https://relay.test/v1/rooms/${room}/${role}${suffix}`, { headers: { Upgrade: "websocket", Authorization: `Bearer ${token}`, "CF-Connecting-IP": "192.0.2.1", ...headers } });
}
const frame = JSON.stringify({ type: "data", n: 0, c: "YWJjZGVmZ2hpamtsbW5vcA==" });
beforeEach(async () => {
  room = await digest(host); phoneHash = await digest(phone);
  vi.stubGlobal("Response", Result);
  vi.stubGlobal("WebSocketPair", class { 0 = new Socket(); 1 = new Socket(); });
});
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe("bounded opaque wire schema", () => {
  it("accepts only the handshake and encrypted frames", () => {
    const hello: any = { type: "hello", public: Buffer.alloc(65).toString("base64"), nonce: Buffer.alloc(32).toString("base64"), proof: Buffer.alloc(32).toString("base64") };
    expect(validFrame(JSON.stringify(hello))).toBe(true);
    expect(validFrame(frame)).toBe(true);
    for (const f of [null, 1, "text", [], {}, { type: "data", n: -1, c: "AA==" }, { type: "data", n: 0.5, c: "AA==" }, { type: "data", n: 0, c: 4 }, { type: "data", n: 0, c: "!" }, { ...JSON.parse(frame), path: "/private-code" }]) expect(validFrame(JSON.stringify(f))).toBe(false);
    for (const key of ["public", "nonce", "proof"]) {
      expect(validFrame(JSON.stringify({ ...hello, [key]: "short" }))).toBe(false);
      expect(validFrame(JSON.stringify({ ...hello, [key]: 1 }))).toBe(false);
    }
    expect(validFrame(JSON.stringify({ ...hello, token: "private" }))).toBe(false);
    expect(validFrame("invalid-json")).toBe(false);
    expect(validFrame("x".repeat(710_001))).toBe(false);
  });
});
describe("edge routing and rate limit", () => {
  it("requires exact routes, upgrades and a source, and enforces the binding", async () => {
    const stub = { fetch: vi.fn(async () => Result.json({ forwarded: true })) };
    const env: any = { ROOMS: { idFromName: (n: string) => n, get: vi.fn(() => stub) }, CONNECTION_LIMIT: { limit: vi.fn(async () => ({ success: true })) } };
    expect((await worker.fetch(new Request("https://relay.test/healthz"), env)).status).toBe(200);
    for (const path of ["/", "/v1/rooms/bad/phone", `/v1/rooms/${room}/other`]) expect((await worker.fetch(new Request("https://relay.test" + path), env)).status).toBe(404);
    expect(route(request("phone"))?.room).toBe(room);
    expect((await worker.fetch(request("phone", phone, {}, "?token=bad"), env)).status).toBe(404);
    expect((await worker.fetch(new Request(request("phone"), { method: "POST" }), env)).status).toBe(426);
    const noUpgrade = request("phone"); noUpgrade.headers.delete("Upgrade");
    expect((await worker.fetch(noUpgrade, env)).status).toBe(426);
    const noIP = request("phone"); noIP.headers.delete("CF-Connecting-IP");
    expect((await worker.fetch(noIP, env)).status).toBe(403);
    expect((await worker.fetch(request("phone"), env)).status).toBe(200);
    expect(env.ROOMS.get).toHaveBeenCalledWith(room);
    env.CONNECTION_LIMIT.limit.mockResolvedValue({ success: false });
    expect((await worker.fetch(request("phone"), env)).status).toBe(429);
  });
});
describe("durable room authorization and opaque forwarding", () => {
  it("authenticates roles separately, survives a hibernated instance and rejects takeover", async () => {
    const ctx = new Context(); const object = new TunnelRoom(ctx as any);
    expect((await object.fetch(new Request("https://relay.test/bad"))).status).toBe(400);
    const invalidUpgrade = request("host"); invalidUpgrade.headers.delete("Upgrade");
    expect((await object.fetch(invalidUpgrade)).status).toBe(400);
    const noAuth = request("host"); noAuth.headers.delete("Authorization");
    expect((await object.fetch(noAuth)).status).toBe(401);
    expect((await object.fetch(request("host", "short"))).status).toBe(401);
    expect((await object.fetch(request("host", phone))).status).toBe(401);
    expect((await object.fetch(request("phone"))).status).toBe(503);
    expect((await object.fetch(request("host"))).status).toBe(400);
    expect((await object.fetch(request("host", host, { "X-Relay-Phone-Hash": "invalid" }))).status).toBe(400);
    expect((await object.fetch(request("host", host, { "X-Relay-Phone-Hash": phoneHash }))).status).toBe(101);
    const hostSocket = ctx.getWebSockets("host")[0];
    expect((await object.fetch(request("host", host, { "X-Relay-Phone-Hash": phoneHash }))).status).toBe(409);
    expect((await object.fetch(request("phone", host))).status).toBe(401);
    const woken = new TunnelRoom(ctx as any);
    expect((await woken.fetch(request("phone"))).status).toBe(101);
    expect((await woken.fetch(request("phone"))).status).toBe(409);
    const mobile = ctx.getWebSockets("phone")[0];
    expect(hostSocket.sent).toContain(JSON.stringify({ type: "peer.joined" }));
    woken.webSocketMessage(mobile as any, frame);
    woken.webSocketMessage(hostSocket as any, frame);
    expect(hostSocket.sent.at(-1)).toBe(frame);
    expect(mobile.sent).toEqual([frame]);
    expect(JSON.stringify([...hostSocket.sent, ...mobile.sent])).not.toContain("private_code_marker");
    woken.webSocketClose(mobile as any);
    expect(hostSocket.sent.at(-1)).toBe(JSON.stringify({ type: "peer.left" }));
    woken.webSocketClose(hostSocket as any);
    expect(mobile.closed.at(-1)).toEqual([1001, "Mac disconnected"]);
    woken.webSocketError(hostSocket as any);
    expect(hostSocket.closed.at(-1)).toEqual([1011, "connection failed"]);
  });
  it("bounds messages, per-second throughput and disconnected peers", async () => {
    const ctx = new Context(); const object = new TunnelRoom(ctx as any);
    await object.fetch(request("host", host, { "X-Relay-Phone-Hash": phoneHash }));
    const server = ctx.getWebSockets("host")[0];
    object.webSocketMessage(server as any, new ArrayBuffer(1));
    object.webSocketMessage(server as any, "{}");
    expect(server.closed.at(-1)?.[0]).toBe(1008);
    object.webSocketMessage(server as any, frame);
    expect(server.closed.at(-1)).toEqual([1001, "peer unavailable"]);
    await object.fetch(request("phone"));
    const state = server.deserializeAttachment(); state.minute -= 2000; server.serializeAttachment(state);
    object.webSocketMessage(server as any, frame);
    expect(server.state.frames).toBe(1);
    server.state.frames = 500;
    object.webSocketMessage(server as any, frame);
    expect(server.closed.at(-1)).toEqual([1008, "rate exceeded"]);
    server.state.frames = 0; server.state.bytes = 2_000_000;
    object.webSocketMessage(server as any, frame);
    expect(server.closed.at(-1)).toEqual([1008, "rate exceeded"]);
    ctx.sockets = []; object.webSocketClose(server as any);
  });
});

it("forwards real cross-language ciphertext without code, API tokens or encryption keys", async () => {
  const fixture = JSON.parse(readFileSync(new URL("../../protocol-fixtures/tunnel-v1.json", import.meta.url), "utf8"));
  const ctx = new Context(), object = new TunnelRoom(ctx as any);
  await object.fetch(request("host", host, { "X-Relay-Phone-Hash": phoneHash }));
  await object.fetch(request("phone"));
  const mac = ctx.getWebSockets("host")[0], mobile = ctx.getWebSockets("phone")[0];
  for (const [socket, value] of [[mobile, fixture.phoneHello], [mac, fixture.hostHello], [mobile, fixture.requestFrame], [mac, fixture.responseFrame]] as const) {
    object.webSocketMessage(socket as any, JSON.stringify(value));
  }
  expect(mac.sent.at(-1)).toBe(JSON.stringify(fixture.requestFrame));
  expect(mobile.sent.at(-1)).toBe(JSON.stringify(fixture.responseFrame));
  const observed = JSON.stringify([...mac.sent, ...mobile.sent]);
  for (const secret of [fixture.secret, fixture.phonePrivate, "private_daemon_token", "private_code_marker", "private_reply_marker", fixture.requestPlain, fixture.responsePlain]) expect(observed).not.toContain(secret);
});
