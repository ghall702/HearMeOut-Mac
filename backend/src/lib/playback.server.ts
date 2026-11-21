// Short-lived signed audio URL for the owner (GET /api/public/v1/recordings/:id/playback).
// Uses the documented media-server token format (handbook §5): base64url(JSON {key, op:"view", exp})
// + "." + base64url(HMAC-SHA256(secret, base64urlPayloadText)). If hmo.server.ts already exports a
// view-token/URL helper (as used by getPlaybackUrl), call that instead of this function.
const VIEW_TTL_SECONDS = 15 * 60;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function keyBelongsToUser(key: string, userId: string) {
  return key.startsWith(`users/${userId.toLowerCase()}/`) && !key.includes("..");
}

export async function signedViewUrl(storageKey: string, now = Math.floor(Date.now() / 1000)) {
  const secret = process.env["HEARMEOUT_GATEWAY_SECRET"];
  if (!secret) throw new Error("Media server not configured");
  const base = (process.env["HEARMEOUT_BASE_URL"] ?? "https://mediahub-lm-1.georgehalltuition.com").replace(/\/$/, "");
  const exp = now + VIEW_TTL_SECONDS;
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ key: storageKey, op: "view", exp })));
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = b64url(new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload))));
  return { url: `${base}/hmo/file?key=${encodeURIComponent(storageKey)}&t=${payload}.${sig}`, exp };
}
