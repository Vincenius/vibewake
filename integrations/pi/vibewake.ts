/**
 * VibeWake integration for pi.
 *
 * Writes marker files to ~/.vibewake/active/ while the agent is working so the
 * VibeWake menu bar app keeps the Mac awake. pi-subagents run as their own pi
 * processes and load this extension too, so each one registers itself.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const dir = path.join(os.homedir(), ".vibewake", "active");
const logFile = path.join(os.homedir(), ".vibewake", "vibewake.log");

const pad = (n: number) => String(n).padStart(2, "0");
const stamp = (d = new Date()) =>
	`${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
const fmtDuration = (seconds: number) => {
	const s = Math.max(0, Math.floor(seconds));
	if (s < 60) return `${s}s`;
	if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
	return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
};

export default function (pi: ExtensionAPI) {
	const pid = process.pid;
	const session = `pi-${pid}`;
	const turnFile = path.join(dir, `${session}.turn.json`);
	const sessionFile = path.join(dir, `${session}.session.json`);
	let cwd = process.cwd();
	let startedAt = 0;

	const write = (file: string, kind: string, started: number) => {
		try {
			fs.mkdirSync(dir, { recursive: true });
			const now = Date.now() / 1000;
			const marker = { agent: "pi", session, kind, pid, cwd, startedAt: started || now, touchedAt: now };
			const tmp = `${file}.tmp${pid}`;
			fs.writeFileSync(tmp, JSON.stringify(marker));
			fs.renameSync(tmp, file);
		} catch {
			// never break pi because of VibeWake
		}
	};
	const remove = (file: string) => {
		try {
			fs.rmSync(file, { force: true });
		} catch {}
	};

	const log = (msg: string) => {
		try {
			fs.mkdirSync(path.dirname(logFile), { recursive: true });
			fs.appendFileSync(logFile, `${stamp()}  [pi]  ${path.basename(cwd)} · pid ${pid}  ${msg}\n`);
		} catch {}
	};

	const busy = () => {
		if (!startedAt) {
			startedAt = Date.now() / 1000;
			log("agent started");
		}
		write(turnFile, "turn", startedAt);
	};
	const idle = () => {
		if (startedAt) log(`agent finished after ${fmtDuration(Date.now() / 1000 - startedAt)}`);
		startedAt = 0;
		remove(turnFile);
	};

	pi.on("session_start", async (_event, ctx) => {
		cwd = ctx.cwd;
		log("session opened");
		write(sessionFile, "session", 0);
	});
	pi.on("agent_start", async (_event, ctx) => {
		cwd = ctx.cwd;
		busy();
	});
	// Heartbeats while working.
	pi.on("turn_start", async () => busy());
	pi.on("tool_execution_start", async () => busy());
	pi.on("tool_execution_end", async () => busy());
	// agent_settled = no retry / compaction / queued follow-up will run anymore.
	pi.on("agent_settled", async () => idle());
	pi.on("session_shutdown", async (event) => {
		idle();
		log(`session closed (${event.reason})`);
		remove(sessionFile);
	});
	process.on("exit", () => {
		remove(turnFile);
		remove(sessionFile);
	});
}
