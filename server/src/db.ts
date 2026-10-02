import { Database } from "bun:sqlite";

export type CommandStatus = "pending" | "delivered" | "done" | "failed" | "expired";

export interface MachineRow {
  id: string;
  name: string;
  model: string;
  token_hash: string;
  last_seen: number;
  sleeping: number;
  next_wake_at: number | null;
  snapshot_json: string | null;
}

export interface CommandRow {
  id: string;
  ref: string | null;
  machine_id: string;
  cmd_json: string;
  status: CommandStatus;
  error: string | null;
  result_json: string | null;
  created_at: number;
  updated_at: number;
}

export interface DeviceRow {
  id: string;
  name: string;
  token_hash: string;
  push_endpoint: string | null;
}

export const now = () => Date.now() / 1000;

export class Store {
  readonly db: Database;

  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS machines (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
        token_hash TEXT NOT NULL UNIQUE, last_seen REAL NOT NULL DEFAULT 0,
        sleeping INTEGER NOT NULL DEFAULT 0, next_wake_at REAL, snapshot_json TEXT
      );
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        push_endpoint TEXT, created_at REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS commands (
        id TEXT PRIMARY KEY, ref TEXT, machine_id TEXT NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
        cmd_json TEXT NOT NULL, status TEXT NOT NULL, error TEXT, result_json TEXT,
        created_at REAL NOT NULL, updated_at REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS commands_open ON commands (machine_id, status, created_at);
      CREATE TABLE IF NOT EXISTS pairing (
        code TEXT PRIMARY KEY, machine_id TEXT NOT NULL, expires_at REAL NOT NULL
      );
    `);
  }

  // Machines

  machine(id: string) {
    return this.db.query<MachineRow, [string]>("SELECT * FROM machines WHERE id = ?").get(id);
  }

  machineByToken(hash: string) {
    return this.db.query<MachineRow, [string]>("SELECT * FROM machines WHERE token_hash = ?").get(hash);
  }

  machines() {
    return this.db.query<MachineRow, []>("SELECT * FROM machines ORDER BY name").all();
  }

  /** Register (or re-register) a Mac; a new token replaces the old one. */
  upsertMachine(id: string, name: string, tokenHash: string) {
    this.db
      .query(
        `INSERT INTO machines (id, name, token_hash, last_seen) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(id) DO UPDATE SET name = ?2, token_hash = ?3`,
      )
      .run(id, name, tokenHash, now());
  }

  updateMachine(id: string, fields: Partial<Omit<MachineRow, "id" | "token_hash">>) {
    const keys = Object.keys(fields) as (keyof typeof fields)[];
    if (!keys.length) return;
    const sql = `UPDATE machines SET ${keys.map((k) => `${k} = ?`).join(", ")} WHERE id = ?`;
    this.db.query(sql).run(...keys.map((k) => fields[k] as any), id);
  }

  deleteMachine(id: string) {
    this.db.query("DELETE FROM machines WHERE id = ?").run(id);
  }

  // Devices

  addDevice(id: string, name: string, tokenHash: string) {
    this.db.query("INSERT INTO devices (id, name, token_hash, created_at) VALUES (?, ?, ?, ?)").run(id, name, tokenHash, now());
  }

  deviceByToken(hash: string) {
    return this.db.query<DeviceRow, [string]>("SELECT * FROM devices WHERE token_hash = ?").get(hash);
  }

  devices() {
    return this.db.query<DeviceRow, []>("SELECT * FROM devices").all();
  }

  setPushEndpoint(id: string, endpoint: string | null) {
    this.db.query("UPDATE devices SET push_endpoint = ? WHERE id = ?").run(endpoint, id);
  }

  deleteDevice(id: string) {
    this.db.query("DELETE FROM devices WHERE id = ?").run(id);
  }

  // Pairing codes

  addPairing(code: string, machineId: string, expiresAt: number) {
    this.db.query("DELETE FROM pairing WHERE expires_at < ?").run(now());
    this.db.query("INSERT INTO pairing (code, machine_id, expires_at) VALUES (?, ?, ?)").run(code, machineId, expiresAt);
  }

  /** Use up a pairing code; true if it was valid. */
  takePairing(code: string) {
    const row = this.db
      .query<{ expires_at: number }, [string]>("DELETE FROM pairing WHERE code = ? RETURNING expires_at")
      .get(code);
    return !!row && row.expires_at > now();
  }

  // Commands

  addCommand(c: { id: string; ref: string | null; machineId: string; cmd: unknown }) {
    const t = now();
    this.db
      .query(
        "INSERT INTO commands (id, ref, machine_id, cmd_json, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'pending', ?, ?)",
      )
      .run(c.id, c.ref, c.machineId, JSON.stringify(c.cmd), t, t);
    return this.command(c.id)!;
  }

  command(id: string) {
    return this.db.query<CommandRow, [string]>("SELECT * FROM commands WHERE id = ?").get(id);
  }

  /** Commands the Mac hasn't acknowledged yet, oldest first. */
  openCommands(machineId: string) {
    return this.db
      .query<CommandRow, [string]>(
        "SELECT * FROM commands WHERE machine_id = ? AND status IN ('pending', 'delivered') ORDER BY created_at",
      )
      .all(machineId);
  }

  recentCommands(limit = 50) {
    return this.db.query<CommandRow, [number]>("SELECT * FROM commands ORDER BY created_at DESC LIMIT ?").all(limit);
  }

  setCommandStatus(id: string, status: CommandStatus, error: string | null = null, result: unknown = null) {
    this.db
      .query("UPDATE commands SET status = ?, error = ?, result_json = ?, updated_at = ? WHERE id = ?")
      .run(status, error, result == null ? null : JSON.stringify(result), now(), id);
    return this.command(id);
  }

  /** Mark open commands older than maxAge seconds as expired; returns them. */
  expireCommands(maxAge: number) {
    return this.db
      .query<CommandRow, [number, number]>(
        `UPDATE commands SET status = 'expired', error = 'the Mac did not pick it up in time', updated_at = ?1
         WHERE status IN ('pending', 'delivered') AND created_at < ?2 RETURNING *`,
      )
      .all(now(), now() - maxAge);
  }

  /** Keep the table small: drop finished commands older than a week. */
  pruneCommands() {
    this.db.query("DELETE FROM commands WHERE status IN ('done', 'failed', 'expired') AND updated_at < ?").run(now() - 7 * 86400);
  }
}
