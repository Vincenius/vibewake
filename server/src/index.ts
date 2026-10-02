import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createRelay } from "./relay";

const setupCode = process.env.SETUP_CODE ?? "";
if (setupCode.length < 12) {
  console.error("Set SETUP_CODE (at least 12 characters): Macs need it to register with this relay.");
  process.exit(1);
}
const dbPath = process.env.DB_PATH ?? "./data/relay.db";
mkdirSync(dirname(dbPath), { recursive: true });

const relay = createRelay({
  dbPath,
  setupCode,
  port: Number(process.env.PORT ?? 8080),
  trustProxy: process.env.TRUST_PROXY === "1",
  allowHttpPush: process.env.ALLOW_HTTP_PUSH === "1",
});
console.log(`VibeWake relay listening on :${relay.server.port}`);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    relay.stop();
    process.exit(0);
  });
}
