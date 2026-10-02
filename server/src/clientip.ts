// Cloudflare's edge ranges (https://www.cloudflare.com/ips/, fetched 2026-10-02).
const CLOUDFLARE = [
  "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
  "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
  "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
  "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
  "2a06:98c0::/29", "2c0f:f248::/32",
].map(parseCidr);

/** An IP address as [bits, value], or null if it isn't one. IPv4-mapped IPv6 counts as IPv4. */
function parseIP(s: string): [32 | 128, bigint] | null {
  const v4 = s.match(/^(?:::ffff:)?(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/i);
  if (v4) {
    const parts = v4.slice(1).map(Number);
    if (parts.some((p) => p > 255)) return null;
    return [32, parts.reduce((a, p) => (a << 8n) | BigInt(p), 0n)];
  }
  if (!s.includes(":") || s.split("::").length > 2) return null;
  const [head, tail] = s.split("::");
  const h = head ? head.split(":") : [];
  const t = tail !== undefined && tail ? tail.split(":") : [];
  const groups = tail === undefined ? h : [...h, ...Array(8 - h.length - t.length).fill("0"), ...t];
  if (groups.length !== 8 || !groups.every((g) => /^[0-9a-f]{1,4}$/i.test(g))) return null;
  return [128, groups.reduce((a, g) => (a << 16n) | BigInt(parseInt(g, 16)), 0n)];
}

function parseCidr(cidr: string): [32 | 128, bigint, number] {
  const [ip, len] = cidr.split("/");
  const [bits, value] = parseIP(ip)!;
  return [bits, value, Number(len)];
}

export function isCloudflare(ip: string): boolean {
  const parsed = parseIP(ip);
  if (!parsed) return false;
  const [bits, value] = parsed;
  return CLOUDFLARE.some(([b, net, len]) => b === bits && value >> BigInt(bits - len) === net >> BigInt(bits - len));
}

/**
 * The client IP for rate limits. Behind a reverse proxy (`trustProxy`) the proxy appends the address it
 * saw as the last X-Forwarded-For entry. If that is a Cloudflare edge, the real client is in
 * CF-Connecting-IP, which only Cloudflare can set on a request coming from its edge.
 */
export function clientIP(headers: Headers, peer: string | undefined, trustProxy: boolean): string {
  if (!trustProxy) return peer ?? "?";
  const forwarded = headers.get("x-forwarded-for")?.split(",").pop()?.trim();
  if (!forwarded) return peer ?? "?";
  const cf = headers.get("cf-connecting-ip")?.trim();
  return cf && isCloudflare(forwarded) && parseIP(cf) ? cf : forwarded;
}
