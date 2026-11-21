import { createFileRoute } from "@tanstack/react-router";
import { authenticateApiKey } from "@/lib/apikeys.server";
import { profileFor } from "@/lib/native-auth.server";
import { json } from "@/lib/api-http.server";

// GET /api/public/v1/me — the profile behind this key (lets API-key clients show the real name/avatar).
export const Route = createFileRoute("/api/public/v1/me")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const auth = await authenticateApiKey(request);
        if (!auth) return json({ error: "unauthorised" }, 401);
        try {
          return json({ user: await profileFor(auth.userId), features: ["native-auth", "playback"] });
        } catch {
          return json({ error: "not_found" }, 404);
        }
      },
    },
  },
});
