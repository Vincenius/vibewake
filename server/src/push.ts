/** What a phone receives through UnifiedPush (ntfy) when something happens on a Mac. */
export interface PushPayload {
  machineId: string;
  machineName: string;
  sessionId: string;
  kind: string;
  title: string;
  text: string;
}

/**
 * POST the payload to a UnifiedPush endpoint (e.g. https://ntfy.example.com/upXYZ?up=1).
 * "gone" means the phone unregistered: the endpoint should be forgotten.
 */
export async function sendPush(endpoint: string, payload: PushPayload): Promise<"ok" | "gone" | "error"> {
  try {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json", TTL: "86400", Urgency: "high" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 404 || res.status === 410) return "gone";
    return res.ok ? "ok" : "error";
  } catch {
    return "error";
  }
}
