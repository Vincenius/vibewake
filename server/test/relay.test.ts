import { afterEach, beforeEach, expect, test } from "bun:test";
import { createRelay } from "../src/relay";
import type { PushPayload } from "../src/push";

const SETUP = "test-setup-code-123";
let relay: ReturnType<typeof createRelay>;
let base: string;
let pushes: { endpoint: string; payload: PushPayload }[];

beforeEach(() => {
  pushes = [];
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
  });
  base = `http://127.0.0.1:${relay.server.port}`;
});

afterEach(() => relay.stop());

const post = (path: string, body: unknown, token?: string) =>
  fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });

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

test("old open commands expire", async () => {
  relay.stop();
  relay = createRelay({ dbPath: ":memory:", setupCode: SETUP, port: 0, hostname: "127.0.0.1", log: () => {}, commandMaxAge: -1 });
  base = `http://127.0.0.1:${relay.server.port}`;
  const mac = await registerMac();
  const device = await pairDevice(mac.token);
  const app = connect("/ws/app", device);
  await app.opened;
  app.send({ type: "command", ref: "a", machineId: mac.machineId, cmd: { type: "continue", sessionId: "s" } });
  await app.nextOf("commandStatus");
  relay.expireNow();
  expect((await app.nextOf("commandStatus")).command.status).toBe("expired");
});
