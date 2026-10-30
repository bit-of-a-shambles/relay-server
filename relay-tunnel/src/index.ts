// Only routing capabilities and ciphertext reach the edge. Never log payloads.
export interface Env { ROOMS: DurableObjectNamespace; CONNECTION_LIMIT: RateLimit }
const hex = /^[a-f0-9]{64}$/;
const error = (status: number, message: string) => Response.json({ error: message }, { status });
export async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, "0")).join("");
}
export function route(request: Request): { room: string; role: string } | null {
  const m = new URL(request.url).pathname.match(/^\/v1\/rooms\/([a-f0-9]{64})\/(host|phone)$/);
  return m ? { room: m[1], role: m[2] } : null;
}
export function validFrame(text: string): boolean {
  if (new TextEncoder().encode(text).length > 710_000) return false;
  let f;
  try { f = JSON.parse(text); } catch { return false; }
  if (!f || typeof f !== "object") return false;
  const keys = Object.keys(f).sort().join(",");
  const b64 = (s: unknown, n?: number) => typeof s === "string" && /^[A-Za-z0-9+/]+={0,2}$/.test(s) && (n === undefined || s.length === n);
  if (f.type === "hello") return keys === "nonce,proof,public,type" && b64(f.public, 88) && b64(f.nonce, 44) && b64(f.proof, 44);
  return f.type === "data" && keys === "c,n,type" && Number.isSafeInteger(f.n) && f.n >= 0 && b64(f.c);
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "GET" && new URL(request.url).pathname === "/healthz") return Response.json({ status: "ok", protocol: 1 });
    const target = route(request);
    if (!target || new URL(request.url).search) return error(404, "not found");
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return error(426, "websocket required");
    const ip = request.headers.get("CF-Connecting-IP");
    if (!ip) return error(403, "connection source required");
    if (!(await env.CONNECTION_LIMIT.limit({ key: ip })).success) return error(429, "connection rate exceeded");
    return env.ROOMS.get(env.ROOMS.idFromName(target.room)).fetch(request);
  }
};
interface Attachment { role: string; phoneHash: string; minute: number; frames: number; bytes: number }
export class TunnelRoom {
  constructor(private ctx: DurableObjectState) {}
  async fetch(request: Request): Promise<Response> {
    const target = route(request);
    if (!target || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return error(400, "invalid room request");
    const token = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
    if (!hex.test(token)) return error(401, "unauthorized");
    const host = this.ctx.getWebSockets("host")[0];
    let phoneHash: string;
    if (target.role === "host") {
      if (await digest(token) !== target.room) return error(401, "unauthorized");
      phoneHash = request.headers.get("X-Relay-Phone-Hash") ?? "";
      if (!hex.test(phoneHash)) return error(400, "phone capability required");
    } else {
      if (!host) return error(503, "Mac is offline");
      phoneHash = (host.deserializeAttachment() as Attachment).phoneHash;
      if (await digest(token) !== phoneHash) return error(401, "unauthorized");
    }
    if (this.ctx.getWebSockets(target.role).length) return error(409, "device already connected");
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.serializeAttachment({ role: target.role, phoneHash, minute: Date.now(), frames: 0, bytes: 0 });
    this.ctx.acceptWebSocket(server, [target.role]);
    if (host) host.send(JSON.stringify({ type: "peer.joined" }));
    return new Response(null, { status: 101, webSocket: client });
  }
  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message !== "string" || !validFrame(message)) { ws.close(1008, "invalid envelope"); return; }
    const state = ws.deserializeAttachment() as Attachment;
    if (Date.now() - state.minute >= 1000) { state.minute = Date.now(); state.frames = state.bytes = 0; }
    state.frames += 1; state.bytes += message.length;
    if (state.frames > 500 || state.bytes > 2_000_000) { ws.close(1008, "rate exceeded"); return; }
    ws.serializeAttachment(state);
    const peer = this.ctx.getWebSockets(state.role === "host" ? "phone" : "host")[0];
    if (!peer) { ws.close(1001, "peer unavailable"); return; }
    peer.send(message);
  }
  webSocketClose(ws: WebSocket): void {
    const state = ws.deserializeAttachment() as Attachment;
    for (const peer of this.ctx.getWebSockets(state.role === "host" ? "phone" : "host")) {
      if (state.role === "host") peer.close(1001, "Mac disconnected");
      else peer.send(JSON.stringify({ type: "peer.left" }));
    }
    ws.close(1000, "closed");
  }
  webSocketError(ws: WebSocket): void { ws.close(1011, "connection failed"); }
}
