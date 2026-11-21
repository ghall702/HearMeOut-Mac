import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";
import { exchangeNativeCode } from "@/lib/native-auth.server";
import { json } from "@/lib/api-http.server";

// POST /api/public/v1/native/token
//   { grant_type: "authorization_code", code, code_verifier, device_name? }
// → 200 { api_key: "hmo_…", user: { id, email, name, avatar_url } } · 400 invalid_request · 401 invalid_grant · 403 not_allowed
export const Route = createFileRoute("/api/public/v1/native/token")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const parsed = z
          .object({
            grant_type: z.literal("authorization_code"),
            code: z.string().min(20).max(2000),
            code_verifier: z.string().min(43).max(128),
            device_name: z.string().max(60).optional(),
          })
          .safeParse(await request.json().catch(() => null));
        if (!parsed.success) return json({ error: "invalid_request" }, 400);
        try {
          return json(await exchangeNativeCode(parsed.data.code, parsed.data.code_verifier, parsed.data.device_name));
        } catch (e) {
          const msg = e instanceof Error ? e.message : "";
          if (msg === "not_allowed") return json({ error: "not_allowed" }, 403);
          if (msg === "could_not_create_key") return json({ error: "could_not_create_key" }, 500);
          return json({ error: "invalid_grant" }, 401);
        }
      },
    },
  },
});
