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
 * Why the relay won't POST to this endpoint, or null if it's fine. The relay fetches whatever a phone
 * registers, so only https (http with `allowHttp`) and no loopback/private/link-local IP literals.
 * Host names aren't resolved: a name pointing at a private address still gets through.
 */
export function pushEndpointError(endpoint: string, allowHttp = false): string | null {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return "not a URL";
  }
  if (url.protocol !== "https:" && !(allowHttp && url.protocol === "http:")) return "must be https";
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || isPrivateIP(host)) return "private address";
  return null;
}

/** Loopback, private, link-local, CGNAT or unspecified IPv4/IPv6 literal (as normalized by `URL`). */
function isPrivateIP(host: string): boolean {
  const v4 = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b < 32) ||
      (a === 192 && b === 168) || (a === 100 && b >= 64 && b < 128);
  }
  if (!host.includes(":")) return false;
  // IPv4-mapped (::ffff:7f00:1, as URL writes ::ffff:127.0.0.1).
  const mapped = host.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (mapped) {
    const hi = parseInt(mapped[1], 16), lo = parseInt(mapped[2], 16);
    return isPrivateIP(`${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`);
  }
  return host === "::" || host === "::1" || /^f[cd]/.test(host) || /^fe[89ab]/.test(host);
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
      // Don't follow redirects: they could point anywhere, including the relay's own network.
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 404 || res.status === 410) return "gone";
    return res.ok ? "ok" : "error";
  } catch {
    return "error";
  }
}
