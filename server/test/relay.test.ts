import { afterEach, beforeEach, expect, test } from "bun:test";
import { createRelay, type RelayOptions } from "../src/relay";
import type { PushPayload } from "../src/push";

const SETUP = "test-setup-code-123";
let relay: ReturnType<typeof createRelay>;
let base: string;
let pushes: { endpoint: string; payload: PushPayload }[];

function start(extra: Partial<RelayOptions> = {}) {
  relay = createRelay({
    dbPath: ":memory:",
    setupCode: SETUP,
    port: 0,
    hostname: "127.0.0.1",
    log: () => {},
    push: async (endpoint, payload) => {
      pushes.push({ endpoint, payload });
      return "ok";
    },
    ...extra,
  });
  base = `http://127.0.0.1:${relay.server.port}`;
}

/** Restart with different options (the default relay is already running). */
function restart(extra: Partial<RelayOptions>) {
  relay.stop();
  start(extra);
}

beforeEach(() => {
  pushes = [];
  start();
});

afterEach(() => relay.stop());

const post = (path: string, body: unknown, token?: string, headers: Record<string, string> = {}) =>
  fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: JSON.stringify(body),
  });

const wrongSetup = (headers: Record<string, string> = {}) =>
  post("/api/mac/register", { setupCode: "nope", machineId: "mac-0001-test", name: "x" }, undefined, headers);

/** A WebSocket client that queues messages so tests can await them in order. */
function connect(path: string, token: string) {
  const ws = new WebSocket(base.replace("http", "ws") + path, { headers: { authorization: `Bearer ${token}` } } as any);
  const inbox: any[] = [];
  const waiters: ((m: any) => void)[] = [];
  let closed: ((code: number) => void) | null = null;
  const closedP = new Promise<number>((r) => (closed = r));
  ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    const w = waiters.shift();
    w ? w(m) : inbox.push(m);
  };
  ws.onclose = (e) => closed!(e.code);
  const opened = new Promise<void>((r, j) => {
    ws.onopen = () => r();
    ws.onerror = () => j(new Error("ws error"));
  });
  return {
    ws,
    opened,
    closed: closedP,
    next: (): Promise<any> =>
      inbox.length
        ? Promise.resolve(inbox.shift())
        : new Promise((r, j) => {
            waiters.push(r);
            setTimeout(() => j(new Error("timeout")), 2000);
          }),
    /** Next message of the given type (skips others). */
    async nextOf(type: string): Promise<any> {
      for (;;) {
        const m = await this.next();
        if (m.type === type) return m;
      }
    },
    send: (m: unknown) => ws.send(JSON.stringify(m)),
  };
}

async function registerMac(machineId = "mac-0001-test") {
  const r = await post("/api/mac/register", { setupCode: SETUP, machineId, name: "Test Mac" });
  expect(r.status).toBe(200);
  return { machineId, token: (await r.json()).token as string };
}

async function pairDevice(macToken: string) {
  const p = await (await post("/api/mac/pair", {}, macToken)).json();
  const r = await post("/api/device/register", { code: p.code, name: "Pixel" });
  expect(r.status).toBe(200);
  return (await r.json()).token as string;
}

test("rejects a wrong setup code and unknown tokens", async () => {
  const r = await post("/api/mac/register", { setupCode: "nope", machineId: "mac-0001-test", name: "x" });
  expect(r.status).toBe(403);
  const ws = connect("/ws/mac", "not-a-token");
  expect(await ws.closed).toBe(4001);
  const app = connect("/ws/app", "not-a-token");
  expect(await app.closed).toBe(4001);
  expect((await fetch(base + "/api/machines")).status).toBe(401);
});

test("pairing codes work once", async () => {
  const mac = await registerMac();
  const p = await (await post("/api/mac/pair", {}, mac.token)).json();
  expect((await post("/api/device/register", { code: p.code, name: "a" })).status).toBe(200);
  expect((await post("/api/device/register", { code: p.code, name: "b" })).status).toBe(403);
});

test("commands flow app → Mac → ack → app", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);

  const m = connect("/ws/mac", mac.token);
  await m.opened;
  expect((await m.next()).type).toBe("synced");
  m.send({ type: "hello", machineId: mac.machineId, name: "Test Mac", model: "Mac15,3" });
  m.send({ type: "snapshot", snapshot: { sessions: [{ id: "claude-1", state: "idle" }] } });

  const app = connect("/ws/app", device);
  await app.opened;
  const machines = await app.nextOf("machines");
  expect(machines.machines[0].online).toBe(true);
  await app.nextOf("commands");

  app.send({ type: "command", ref: "r1", machineId: mac.machineId, cmd: { type: "sendNow", sessionId: "claude-1", text: "hi" } });
  expect((await app.nextOf("commandStatus")).command.status).toBe("pending");
  const cmd = await m.nextOf("command");
  expect(cmd.cmd).toEqual({ type: "sendNow", sessionId: "claude-1", text: "hi" });
  expect((await app.nextOf("commandStatus")).command.status).toBe("delivered");

  m.send({ type: "ack", id: cmd.id, ok: true, result: { via: "inbox" } });
  const done = (await app.nextOf("commandStatus")).command;
  expect(done).toMatchObject({ ref: "r1", status: "done", result: { via: "inbox" } });
});

test("rejects malformed commands", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const app = connect("/ws/app", device);
  await app.opened;
  app.send({ type: "command", ref: "x", machineId: mac.machineId, cmd: { type: "rm -rf", sessionId: "a" } });
  expect((await app.nextOf("error")).error).toBeTruthy();
});

test("commands sent while the Mac sleeps are delivered on reconnect, then synced", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const app = connect("/ws/app", device);
  await app.opened;

  let m = connect("/ws/mac", mac.token);
  await m.opened;
  await m.nextOf("synced");
  m.send({ type: "sleeping", nextWakeAt: 1234 });
  m.ws.close();
  let asleep;
  do asleep = (await app.nextOf("machine")).machine;
  while (asleep.online);
  expect(asleep).toMatchObject({ online: false, sleeping: true, nextWakeAt: 1234 });

  app.send({ type: "command", ref: "a", machineId: mac.machineId, cmd: { type: "queueAdd", sessionId: "s", text: "one" } });
  app.send({ type: "command", ref: "b", machineId: mac.machineId, cmd: { type: "askStatus", sessionId: "s" } });
  await app.nextOf("commandStatus");
  await app.nextOf("commandStatus");

  m = connect("/ws/mac", mac.token);
  await m.opened;
  const first = await m.next();
  const second = await m.next();
  expect([first.cmd.type, second.cmd.type]).toEqual(["queueAdd", "askStatus"]);
  expect((await m.next()).type).toBe("synced");

  // Not acked yet: a further reconnect gets them again (the Mac dedupes by id).
  m.ws.close();
  await m.closed;
  m = connect("/ws/mac", mac.token);
  await m.opened;
  expect((await m.next()).id).toBe(first.id);
});

test("events become pushes to registered devices", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  expect((await post("/api/device/push", { endpoint: "https://ntfy.example.com/upABC?up=1" }, device)).status).toBe(200);

  const m = connect("/ws/mac", mac.token);
  await m.opened;
  m.send({ type: "event", event: { kind: "finished", sessionId: "claude-1", title: "Fix bug", text: "x".repeat(500) } });
  await Bun.sleep(50);
  expect(pushes).toHaveLength(1);
  expect(pushes[0].endpoint).toBe("https://ntfy.example.com/upABC?up=1");
  expect(pushes[0].payload).toMatchObject({ kind: "finished", machineName: "Test Mac", title: "Fix bug" });
  expect(pushes[0].payload.text).toHaveLength(300);
});

test("with the lid open, only subscribed phones get finished/failed; limited/waiting always go out", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  expect((await post("/api/device/push", { endpoint: "https://ntfy.example.com/upABC?up=1" }, device)).status).toBe(200);
  const m = connect("/ws/mac", mac.token);
  await m.opened;
  const app = connect("/ws/app", device);
  await app.opened;
  expect((await app.nextOf("subscriptions")).subscriptions).toEqual([]);
  const event = (kind: string, sessionId: string, away: boolean) =>
    m.send({ type: "event", event: { kind, sessionId, title: "t", text: "x", away } });

  event("finished", "claude-1", false);
  event("failed", "claude-1", false);
  event("waiting", "claude-1", false);
  event("limited", "claude-1", false);
  event("finished", "claude-2", true);
  await Bun.sleep(50);
  expect(pushes.map((p) => `${p.payload.kind} ${p.payload.sessionId}`)).toEqual(["waiting claude-1", "limited claude-1", "finished claude-2"]);

  pushes = [];
  app.send({ type: "subscribe", machineId: mac.machineId, sessionId: "claude-1", on: true });
  expect((await app.nextOf("subscriptions")).subscriptions).toEqual([{ machineId: mac.machineId, sessionId: "claude-1" }]);
  event("finished", "claude-1", false);
  event("finished", "claude-3", false);
  await Bun.sleep(50);
  expect(pushes.map((p) => p.payload.sessionId)).toEqual(["claude-1"]);

  app.send({ type: "subscribe", machineId: mac.machineId, sessionId: "claude-1", on: false });
  expect((await app.nextOf("subscriptions")).subscriptions).toEqual([]);
});

test("prompts from a phone subscribe it, also to the new chat a newSession starts", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const m = connect("/ws/mac", mac.token);
  await m.opened;
  const app = connect("/ws/app", device);
  await app.opened;
  await app.nextOf("subscriptions");

  app.send({ type: "command", ref: "a", machineId: mac.machineId, cmd: { type: "sendNow", sessionId: "claude-1", text: "go" } });
  expect((await app.nextOf("subscriptions")).subscriptions.map((s: any) => s.sessionId)).toEqual(["claude-1"]);

  m.send({ type: "snapshot", snapshot: { sessions: [{ id: "claude-1", cwd: "/p" }] } });
  app.send({ type: "command", ref: "b", machineId: mac.machineId, cmd: { type: "newSession", cwd: "/p", prompt: "hi" } });
  while ((await app.nextOf("commandStatus")).command.ref !== "b");
  m.send({ type: "snapshot", snapshot: { sessions: [{ id: "claude-1", cwd: "/p" }, { id: "claude-9", cwd: "/q" }] } });
  m.send({ type: "snapshot", snapshot: { sessions: [{ id: "claude-1", cwd: "/p" }, { id: "claude-9", cwd: "/q" }, { id: "claude-2", cwd: "/p" }] } });
  expect((await app.nextOf("subscriptions")).subscriptions.map((s: any) => s.sessionId)).toEqual(["claude-1", "claude-2"]);
});

test("events from Macs that don't send `away` reach every phone", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  expect((await post("/api/device/push", { endpoint: "https://ntfy.example.com/upABC?up=1" }, device)).status).toBe(200);
  const m = connect("/ws/mac", mac.token);
  await m.opened;
  m.send({ type: "event", event: { kind: "finished", sessionId: "claude-1", title: "t", text: "x" } });
  await Bun.sleep(50);
  expect(pushes).toHaveLength(1);
});

test("old open commands expire", async () => {
  restart({ commandMaxAge: -1 });
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const app = connect("/ws/app", device);
  await app.opened;
  app.send({ type: "command", ref: "a", machineId: mac.machineId, cmd: { type: "continue", sessionId: "s" } });
  await app.nextOf("commandStatus");
  relay.expireNow();
  expect((await app.nextOf("commandStatus")).command.status).toBe("expired");
});

test("unpairing deletes the device and closes its connections", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  expect((await post("/api/device/push", { endpoint: "https://ntfy.example.com/upABC?up=1" }, device)).status).toBe(200);
  const app = connect("/ws/app", device);
  await app.opened;

  const unpair = () => fetch(base + "/api/device", { method: "DELETE", headers: { authorization: `Bearer ${device}` } });
  expect((await unpair()).status).toBe(204);
  expect(await app.closed).toBe(4001);
  expect(relay.store.devices()).toHaveLength(0);
  expect((await fetch(base + "/api/machines", { headers: { authorization: `Bearer ${device}` } })).status).toBe(401);
  expect((await unpair()).status).toBe(401);
  expect(await connect("/ws/app", device).closed).toBe(4001);
});

test("parallel wrong guesses can't get past the rate limit; right ones don't count", async () => {
  for (let i = 0; i < 12; i++) await registerMac(`mac-00${i}-test`);
  const statuses = (await Promise.all(Array.from({ length: 15 }, () => wrongSetup()))).map((r) => r.status);
  expect(statuses.filter((s) => s === 403)).toHaveLength(10);
  expect(statuses.filter((s) => s === 429)).toHaveLength(5);
});

test("X-Forwarded-For is ignored by default", async () => {
  for (let i = 0; i < 10; i++) expect((await wrongSetup({ "x-forwarded-for": `10.0.0.${i}` })).status).toBe(403);
  expect((await wrongSetup({ "x-forwarded-for": "10.0.0.99" })).status).toBe(429);
});

test("with trustProxy the rate limit is per last X-Forwarded-For entry", async () => {
  restart({ trustProxy: true });
  for (let i = 0; i < 10; i++) expect((await wrongSetup({ "x-forwarded-for": `1.1.1.${i}, 5.6.7.8` })).status).toBe(403);
  expect((await wrongSetup({ "x-forwarded-for": "9.9.9.9, 5.6.7.8" })).status).toBe(429);
  expect((await wrongSetup({ "x-forwarded-for": "5.6.7.8, 1.2.3.4" })).status).toBe(403);
  // Without the header the socket address counts.
  expect((await wrongSetup()).status).toBe(403);
});

test("via Cloudflare the rate limit is per CF-Connecting-IP, only when the proxy saw a Cloudflare edge", async () => {
  restart({ trustProxy: true });
  const viaCf = (client: string) => ({ "x-forwarded-for": "172.64.1.1", "cf-connecting-ip": client });
  for (let i = 0; i < 10; i++) expect((await wrongSetup(viaCf(`1.1.1.${i}`))).status).toBe(403);
  // Different Cloudflare edges, same client: still limited.
  expect((await wrongSetup({ "x-forwarded-for": "2606:4700::1", "cf-connecting-ip": "1.1.1.0" })).status).toBe(429);
  // Same edge, another client: not limited.
  expect((await wrongSetup(viaCf("8.8.8.8"))).status).toBe(403);
  // Not from Cloudflare: a forged CF-Connecting-IP is ignored, the proxy's peer counts.
  for (let i = 0; i < 9; i++) await wrongSetup({ "x-forwarded-for": "5.6.7.8", "cf-connecting-ip": `9.9.9.${i}` });
  expect((await wrongSetup({ "x-forwarded-for": "5.6.7.8", "cf-connecting-ip": "9.9.9.200" })).status).toBe(429);
});

test("push endpoints must be https and public", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const set = (endpoint: string | null) => post("/api/device/push", { endpoint }, device);
  expect((await set("https://ntfy.example.com/upABC?up=1")).status).toBe(200);
  for (const bad of [
    "http://ntfy.example.com/up",
    "ftp://ntfy.example.com/up",
    "not a url",
    "https://localhost/up",
    "https://127.0.0.1/up",
    "https://2130706433/up", // 127.0.0.1
    "https://10.1.2.3/up",
    "https://172.20.0.1/up",
    "https://192.168.1.1/up",
    "https://169.254.169.254/latest",
    "https://[::1]/up",
    "https://[::ffff:127.0.0.1]/up",
    "https://[fd00::1]/up",
    "https://[fe80::1]/up",
  ]) {
    expect({ bad, status: (await set(bad)).status }).toEqual({ bad, status: 400 });
  }
  // A rejected endpoint doesn't replace the previous one.
  expect(relay.store.devices()[0].push_endpoint).toBe("https://ntfy.example.com/upABC?up=1");
  expect((await set(null)).status).toBe(200);
  expect(relay.store.devices()[0].push_endpoint).toBeNull();

  restart({ allowHttpPush: true });
  const device2 = await pairDevice((await registerMac()).token);
  expect((await post("/api/device/push", { endpoint: "http://ntfy:80/upABC?up=1" }, device2)).status).toBe(200);
  expect((await post("/api/device/push", { endpoint: "http://127.0.0.1/up" }, device2)).status).toBe(400);
});

test("malformed snapshots are dropped", async () => {
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const m = connect("/ws/mac", mac.token);
  await m.opened;
  await m.nextOf("synced");
  const app = connect("/ws/app", device);
  await app.opened;
  await app.nextOf("commands");

  const session = { id: "claude-1", state: "idle", queue: [{ id: "q1", text: "hi", mode: "sameChat", createdAt: 1 }] };
  for (const bad of [
    { battery: "full", sessions: [session] },
    { battery: { onBattery: true }, sessions: [session] },
    { sessions: [{ state: "idle" }] },
    { sessions: [{ ...session, queue: [{ text: "no id" }] }] },
    { sessions: [{ ...session, reply: { at: 1 } }] },
    { sessions: "none" },
    { paused: "yes" },
  ]) m.send({ type: "snapshot", snapshot: bad });
  // Optional fields may be missing or null; unknown ones pass through.
  const good = {
    paused: false,
    battery: null,
    future: 1,
    sessions: [{ ...session, project: null, reply: { text: "done", at: 2, truncated: false } }],
  };
  m.send({ type: "snapshot", snapshot: good });

  let machine;
  do machine = (await app.nextOf("machine")).machine;
  while (!machine.snapshot);
  expect(machine.snapshot).toMatchObject(good);
});
