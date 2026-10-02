# VibeWake remote protocol

Three parties: **Mac** (VibeWake app), **relay** (`server/`), **app** (`android/`).
Macs and phones only make outbound connections to the relay. All times are epoch **seconds** (floating point).
Every WebSocket message is one JSON object with a `type`.

## Auth and pairing (REST)

| Request | Auth | Body → Response |
|---|---|---|
| `POST /api/mac/register` | none | `{setupCode, machineId, name}` → `{token}` — `setupCode` is the relay's `SETUP_CODE` |
| `POST /api/mac/pair` | Bearer mac token | → `{code, expiresAt}` — one-time phone pairing code, valid 5 min |
| `POST /api/device/register` | none | `{code, name}` → `{token, deviceId}` |
| `POST /api/device/push` | Bearer device token | `{endpoint: string \| null}` — UnifiedPush endpoint |
| `GET /api/machines` | Bearer device token | → `{machines: Machine[]}` |
| `GET /healthz` | none | → `ok` |

The Mac shows the pairing code as a QR code: `vibewake://pair?server=<https base URL>&code=<code>`.
Tokens are 32 random bytes (base64url). The relay stores only their SHA-256.

## Mac ⇄ relay: `GET /ws/mac` (header `Authorization: Bearer <mac token>`)

Mac → relay:
- `{type:"hello", machineId, name, model, appVersion}` — first message after connecting.
- `{type:"snapshot", snapshot: Snapshot}` — whenever it changes.
- `{type:"ping"}` — every 25 s, keeps `lastSeen` fresh.
- `{type:"event", event: {kind, sessionId, title, text}}`. `kind` is one of `finished | failed | limited | waiting`.
- `{type:"ack", id, ok, error?, result?}` — the outcome of one command.
- `{type:"sleeping", nextWakeAt: number | null}` — sent just before the Mac sleeps.

Relay → Mac:
- `{type:"command", id, cmd: Command}` — pending commands, sent oldest first on every (re)connect and live afterwards. The Mac may receive a command again after a reconnect. It answers a repeated `id` with the ack it sent the first time and does not run the command again.
- `{type:"synced"}` — all pending commands have been sent. After a scheduled wake the Mac goes back to sleep soon after this, unless there is work to do.

## App ⇄ relay: `GET /ws/app` (header `Authorization: Bearer <device token>`)

Relay → app:
- `{type:"machines", machines: Machine[]}` — on connect.
- `{type:"machine", machine: Machine}` — when a Mac's state or snapshot changes.
- `{type:"commands", commands: CommandRecord[]}` — recent commands, on connect.
- `{type:"commandStatus", command: CommandRecord}` — on every status change.

App → relay:
- `{type:"command", ref, machineId, cmd: Command}` — `ref` is the app's own id. It is echoed in the `CommandRecord`.

## Types

```ts
Machine = { id, name, model, online: boolean, lastSeen: number, sleeping: boolean,
            nextWakeAt: number | null, snapshot: Snapshot | null }

Snapshot = {
  at: number, paused: boolean, remoteControl: boolean, lidClosed: boolean,
  battery: { onBattery: boolean, percent: number } | null,
  nobodyAtScreen: boolean,          // locked / lid closed → new chats run headless
  wakeIntervalMinutes: number,      // 0 = never wakes on its own
  projects: string[],               // folders newSession may use
  sessions: Session[]
}

Session = {
  id: string,                       // "<agent>-<session id>", stable
  agent: string, session: string, project: string | null, cwd: string | null, title: string,
  state: "working" | "idle" | "limited" | "stalled" | "waiting" | "finished" | "failed",
  stateSince: number | null, limitedUntil: number | null, subagents: number,
  canReceive: boolean,              // prompts can be sent
  headless: boolean,                // run with `claude -p` (resumed per prompt)
  blocked: string | null,           // why the autopilot paused this chat
  next: string | null,              // what the autopilot does next
  queue: { id: string, text: string, mode: "sameChat" | "newChat", createdAt: number }[],
  reply: { text: string, at: number, truncated: boolean } | null   // first 8 KB of the last reply
}

Command =
  | { type:"queueAdd",    sessionId, text, mode: "sameChat" | "newChat" }
  | { type:"queueRemove", sessionId, itemId }
  | { type:"queueMove",   sessionId, itemId, by: number }       // -1 = up
  | { type:"queueEdit",   sessionId, itemId, text?, mode? }
  | { type:"sendNow",     sessionId, text }
  | { type:"askStatus",   sessionId }
  | { type:"continue",    sessionId }
  | { type:"resumeQueue", sessionId }
  | { type:"newSession",  cwd, prompt }
  | { type:"fetchReply",  sessionId }                          // result: { text, at }
  | { type:"setPaused",   paused: boolean }

CommandRecord = { id, ref: string | null, machineId, cmd: Command,
                  status: "pending" | "delivered" | "done" | "failed" | "expired",
                  error: string | null, result: any | null, createdAt: number, updatedAt: number }
```

A pending command expires after 24 hours.

Push notifications are sent to each device's UnifiedPush endpoint as a JSON body:
`{machineId, machineName, sessionId, kind, title, text}`. `text` is at most 300 characters.
