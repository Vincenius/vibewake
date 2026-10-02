import type { Server, ServerWebSocket } from "bun";
import { z } from "zod";
import { Store, now, type CommandRow, type MachineRow } from "./db";
import { sendPush, type PushPayload } from "./push";

/** See protocol/PROTOCOL.md for every message. */

const sessionId = z.string().min(1).max(200);
const itemId = z.string().min(1).max(64);
const text = z.string().min(1).max(100_000);
const mode = z.enum(["sameChat", "newChat"]);

export const Command = z.discriminatedUnion("type", [
  z.object({ type: z.literal("queueAdd"), sessionId, text, mode: mode.default("sameChat") }),
  z.object({ type: z.literal("queueRemove"), sessionId, itemId }),
  z.object({ type: z.literal("queueMove"), sessionId, itemId, by: z.number().int().min(-1000).max(1000) }),
  z.object({ type: z.literal("queueEdit"), sessionId, itemId, text: text.optional(), mode: mode.optional() }),
  z.object({ type: z.literal("sendNow"), sessionId, text }),
  z.object({ type: z.literal("askStatus"), sessionId }),
  z.object({ type: z.literal("continue"), sessionId }),
  z.object({ type: z.literal("resumeQueue"), sessionId }),
  z.object({ type: z.literal("newSession"), cwd: z.string().min(1).max(4096), prompt: text }),
  z.object({ type: z.literal("fetchReply"), sessionId }),
  z.object({ type: z.literal("setPaused"), paused: z.boolean() }),
]);

const MacMessage = z.discriminatedUnion("type", [
  z.object({ type: z.literal("hello"), machineId: z.string(), name: z.string().max(200), model: z.string().max(100).default(""), appVersion: z.string().optional() }),
  z.object({ type: z.literal("snapshot"), snapshot: z.record(z.unknown()) }),
  z.object({ type: z.literal("ping") }),
  z.object({
    type: z.literal("event"),
    event: z.object({ kind: z.enum(["finished", "failed", "limited", "waiting"]), sessionId: z.string(), title: z.string(), text: z.string() }),
  }),
  z.object({ type: z.literal("ack"), id: z.string(), ok: z.boolean(), error: z.string().optional(), result: z.unknown().optional() }),
  z.object({ type: z.literal("sleeping"), nextWakeAt: z.number().nullable() }),
]);

const AppMessage = z.discriminatedUnion("type", [
  z.object({ type: z.literal("command"), ref: z.string().max(100).nullable().default(null), machineId: z.string(), cmd: Command }),
]);

type WSData = { kind: "mac"; machineId: string } | { kind: "app"; deviceId: string } | { kind: "rejected" };

export interface RelayOptions {
  dbPath: string;
  setupCode: string;
  port?: number;
  hostname?: string;
  /** Open commands older than this expire (seconds). */
  commandMaxAge?: number;
  push?: (endpoint: string, payload: PushPayload) => Promise<"ok" | "gone" | "error">;
  log?: (msg: string) => void;
}

// Close code that tells a Mac its token is unknown (don't keep retrying).
const REJECTED = 4001;
const PAIRING_TTL = 5 * 60;

export async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Buffer.from(buf).toString("hex");
}

function randomToken(bytes = 32) {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(bytes))).toString("base64url");
}

/** A short code that's easy to read off a screen if the QR can't be scanned. */
function pairingCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

function bearer(req: Request) {
  const h = req.headers.get("authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7).trim() : null;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** Constant-time string compare. */
function safeEqual(a: string, b: string) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

/** Failed guesses (setup code, pairing code) per IP: 10 per 10 minutes. */
class Throttle {
  private hits = new Map<string, number[]>();
  blocked(ip: string) {
    const t = now();
    const list = (this.hits.get(ip) ?? []).filter((x) => t - x < 600);
    this.hits.set(ip, list);
    return list.length >= 10;
  }
  fail(ip: string) {
    this.hits.set(ip, [...(this.hits.get(ip) ?? []), now()]);
  }
}

export function createRelay(opts: RelayOptions) {
  const store = new Store(opts.dbPath);
  const log = opts.log ?? ((m: string) => console.log(new Date().toISOString(), m));
  const push = opts.push ?? sendPush;
  const commandMaxAge = opts.commandMaxAge ?? 24 * 3600;
  const throttle = new Throttle();
  const macs = new Map<string, ServerWebSocket<WSData>>();
  const apps = new Set<ServerWebSocket<WSData>>();
  let server: Server<WSData>;

  const machineView = (m: MachineRow) => ({
    id: m.id,
    name: m.name,
    model: m.model,
    online: macs.has(m.id),
    lastSeen: m.last_seen,
    sleeping: !!m.sleeping && !macs.has(m.id),
    nextWakeAt: m.next_wake_at,
    snapshot: m.snapshot_json ? JSON.parse(m.snapshot_json) : null,
  });

  const commandView = (c: CommandRow) => ({
    id: c.id,
    ref: c.ref,
    machineId: c.machine_id,
    cmd: JSON.parse(c.cmd_json),
    status: c.status,
    error: c.error,
    result: c.result_json ? JSON.parse(c.result_json) : null,
    createdAt: c.created_at,
    updatedAt: c.updated_at,
  });

  const toApps = (msg: unknown) => {
    const s = JSON.stringify(msg);
    for (const ws of apps) ws.send(s);
  };
  const broadcastMachine = (id: string) => {
    const m = store.machine(id);
    if (m) toApps({ type: "machine", machine: machineView(m) });
  };
  const broadcastCommand = (c: CommandRow | null) => {
    if (c) toApps({ type: "commandStatus", command: commandView(c) });
  };

  const deliver = (ws: ServerWebSocket<WSData>, c: CommandRow) => {
    ws.send(JSON.stringify({ type: "command", id: c.id, cmd: JSON.parse(c.cmd_json) }));
    if (c.status === "pending") broadcastCommand(store.setCommandStatus(c.id, "delivered"));
  };

  async function notify(machine: MachineRow, ev: { kind: string; sessionId: string; title: string; text: string }) {
    const payload: PushPayload = {
      machineId: machine.id,
      machineName: machine.name,
      sessionId: ev.sessionId,
      kind: ev.kind,
      title: ev.title,
      text: ev.text.slice(0, 300),
    };
    for (const d of store.devices()) {
      if (!d.push_endpoint) continue;
      const r = await push(d.push_endpoint, payload);
      if (r === "gone") {
        log(`push endpoint of device ${d.name} is gone; removed`);
        store.setPushEndpoint(d.id, null);
      }
    }
  }

  // MARK: HTTP

  async function handleHttp(req: Request, srv: Server<WSData>): Promise<Response | undefined> {
    const url = new URL(req.url);
    const ip = srv.requestIP(req)?.address ?? "?";
    const body = async () => {
      try {
        return (await req.json()) as Record<string, unknown>;
      } catch {
        return {};
      }
    };

    if (url.pathname === "/healthz") return new Response("ok");

    if (url.pathname === "/ws/mac" || url.pathname === "/ws/app") {
      const token = bearer(req);
      const hash = token ? await sha256(token) : "";
      let data: WSData = { kind: "rejected" };
      if (url.pathname === "/ws/mac") {
        const m = token ? store.machineByToken(hash) : null;
        if (m) data = { kind: "mac", machineId: m.id };
      } else {
        const d = token ? store.deviceByToken(hash) : null;
        if (d) data = { kind: "app", deviceId: d.id };
      }
      // Upgrade even when rejected, so the client gets a close code it can act on.
      if (srv.upgrade(req, { data })) return undefined;
      return new Response("expected a WebSocket", { status: 400 });
    }

    if (req.method === "POST" && url.pathname === "/api/mac/register") {
      if (throttle.blocked(ip)) return json({ error: "too many attempts" }, 429);
      const b = await body();
      const ok = typeof b.setupCode === "string" && safeEqual(b.setupCode, opts.setupCode);
      if (!ok || typeof b.machineId !== "string" || !/^[\w-]{8,64}$/.test(b.machineId)) {
        throttle.fail(ip);
        return json({ error: "wrong setup code" }, 403);
      }
      const token = randomToken();
      const name = typeof b.name === "string" && b.name ? b.name.slice(0, 200) : "Mac";
      store.upsertMachine(b.machineId, name, await sha256(token));
      // A re-registered Mac drops its old connection (old token).
      macs.get(b.machineId)?.close(REJECTED, "re-registered");
      log(`registered Mac ${name} (${b.machineId})`);
      broadcastMachine(b.machineId);
      return json({ token });
    }

    if (req.method === "POST" && url.pathname === "/api/mac/pair") {
      const token = bearer(req);
      const m = token ? store.machineByToken(await sha256(token)) : null;
      if (!m) return json({ error: "unknown Mac" }, 401);
      const code = pairingCode();
      const expiresAt = now() + PAIRING_TTL;
      store.addPairing(code, m.id, expiresAt);
      return json({ code, expiresAt });
    }

    if (req.method === "POST" && url.pathname === "/api/device/register") {
      if (throttle.blocked(ip)) return json({ error: "too many attempts" }, 429);
      const b = await body();
      if (typeof b.code !== "string" || !store.takePairing(b.code.toUpperCase())) {
        throttle.fail(ip);
        return json({ error: "pairing code is wrong or expired" }, 403);
      }
      const token = randomToken();
      const deviceId = crypto.randomUUID();
      const name = typeof b.name === "string" && b.name ? b.name.slice(0, 200) : "Phone";
      store.addDevice(deviceId, name, await sha256(token));
      log(`paired device ${name}`);
      return json({ token, deviceId });
    }

    // Everything below needs a device token.
    if (url.pathname.startsWith("/api/")) {
      const token = bearer(req);
      const device = token ? store.deviceByToken(await sha256(token)) : null;
      if (!device) return json({ error: "unknown device" }, 401);

      if (req.method === "POST" && url.pathname === "/api/device/push") {
        const b = await body();
        const endpoint = typeof b.endpoint === "string" && /^https?:\/\//.test(b.endpoint) ? b.endpoint : null;
        store.setPushEndpoint(device.id, endpoint);
        return json({ ok: true });
      }
      if (req.method === "GET" && url.pathname === "/api/machines") {
        return json({ machines: store.machines().map(machineView) });
      }
      const del = url.pathname.match(/^\/api\/machines\/([\w-]+)$/);
      if (req.method === "DELETE" && del) {
        macs.get(del[1])?.close(REJECTED, "removed");
        store.deleteMachine(del[1]);
        toApps({ type: "machines", machines: store.machines().map(machineView) });
        return json({ ok: true });
      }
    }
    return json({ error: "not found" }, 404);
  }

  // MARK: WebSocket

  function onMacMessage(ws: ServerWebSocket<WSData> & { data: { kind: "mac" } }, raw: string) {
    const id = ws.data.machineId;
    let parsed;
    try {
      parsed = MacMessage.safeParse(JSON.parse(raw));
    } catch {
      return;
    }
    if (!parsed.success) return log(`bad message from Mac ${id}: ${parsed.error.issues[0]?.message}`);
    const msg = parsed.data;
    const t = now();
    switch (msg.type) {
      case "hello":
        store.updateMachine(id, { name: msg.name, model: msg.model, last_seen: t, sleeping: 0, next_wake_at: null });
        broadcastMachine(id);
        break;
      case "snapshot":
        store.updateMachine(id, { snapshot_json: JSON.stringify({ ...msg.snapshot, at: t }), last_seen: t });
        broadcastMachine(id);
        break;
      case "ping":
        store.updateMachine(id, { last_seen: t });
        break;
      case "event": {
        const m = store.machine(id);
        if (m) void notify(m, msg.event);
        break;
      }
      case "ack": {
        const c = store.command(msg.id);
        if (!c || c.machine_id !== id) break;
        broadcastCommand(store.setCommandStatus(msg.id, msg.ok ? "done" : "failed", msg.error ?? null, msg.result ?? null));
        break;
      }
      case "sleeping":
        store.updateMachine(id, { sleeping: 1, next_wake_at: msg.nextWakeAt, last_seen: t });
        broadcastMachine(id);
        break;
    }
  }

  function onAppMessage(ws: ServerWebSocket<WSData>, raw: string) {
    let parsed;
    try {
      parsed = AppMessage.safeParse(JSON.parse(raw));
    } catch {
      return;
    }
    if (!parsed.success) {
      ws.send(JSON.stringify({ type: "error", error: parsed.error.issues[0]?.message ?? "bad message" }));
      return;
    }
    const msg = parsed.data;
    if (!store.machine(msg.machineId)) {
      ws.send(JSON.stringify({ type: "error", ref: msg.ref, error: "unknown machine" }));
      return;
    }
    const c = store.addCommand({ id: crypto.randomUUID(), ref: msg.ref, machineId: msg.machineId, cmd: msg.cmd });
    broadcastCommand(c);
    const mac = macs.get(msg.machineId);
    if (mac) deliver(mac, c);
  }

  server = Bun.serve<WSData>({
    port: opts.port ?? 8080,
    hostname: opts.hostname ?? "0.0.0.0",
    fetch: (req, srv) => handleHttp(req, srv),
    websocket: {
      idleTimeout: 90, // Macs ping every 25 s
      maxPayloadLength: 8 << 20,
      open(ws) {
        if (ws.data.kind === "rejected") return ws.close(REJECTED, "unknown token");
        if (ws.data.kind === "mac") {
          const id = ws.data.machineId;
          macs.get(id)?.close(1000, "replaced by a new connection");
          macs.set(id, ws);
          store.updateMachine(id, { last_seen: now(), sleeping: 0 });
          log(`Mac ${store.machine(id)?.name ?? id} connected`);
          for (const c of store.openCommands(id)) deliver(ws, c);
          ws.send(JSON.stringify({ type: "synced" }));
          broadcastMachine(id);
        } else {
          apps.add(ws);
          ws.send(JSON.stringify({ type: "machines", machines: store.machines().map(machineView) }));
          ws.send(JSON.stringify({ type: "commands", commands: store.recentCommands().map(commandView) }));
        }
      },
      message(ws, message) {
        const raw = typeof message === "string" ? message : new TextDecoder().decode(message);
        if (ws.data.kind === "mac") onMacMessage(ws as any, raw);
        else if (ws.data.kind === "app") onAppMessage(ws, raw);
      },
      close(ws) {
        if (ws.data.kind === "mac") {
          const id = ws.data.machineId;
          if (macs.get(id) === ws) {
            macs.delete(id);
            log(`Mac ${store.machine(id)?.name ?? id} disconnected`);
            broadcastMachine(id);
          }
        } else if (ws.data.kind === "app") {
          apps.delete(ws);
        }
      },
    },
  });

  const housekeeping = setInterval(() => {
    for (const c of store.expireCommands(commandMaxAge)) broadcastCommand(c);
    store.pruneCommands();
  }, 60_000);

  return {
    server,
    store,
    expireNow: () => store.expireCommands(commandMaxAge).forEach(broadcastCommand),
    stop() {
      clearInterval(housekeeping);
      server.stop(true);
      store.db.close();
    },
  };
}
