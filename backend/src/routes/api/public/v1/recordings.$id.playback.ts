import { createFileRoute } from "@tanstack/react-router";
import { authenticateApiKey } from "@/lib/apikeys.server";
import { getOwnedRecording } from "@/lib/recordings.server";
import { keyBelongsToUser, signedViewUrl } from "@/lib/playback.server";
import { json } from "@/lib/api-http.server";

// GET /api/public/v1/recordings/:id/playback — owner-only, 15-minute signed audio URL (supports Range).
// The client never signs storage tokens; audio is streamed directly from the media server.
export const Route = createFileRoute("/api/public/v1/recordings/$id/playback")({
  server: {
    handlers: {
      GET: async ({ request, params }) => {
        const auth = await authenticateApiKey(request);
        if (!auth) return json({ error: "unauthorised" }, 401);
        try {
          const rec = await getOwnedRecording(auth.db, auth.userId, params.id);
          if (rec.status !== "ready") return json({ error: "not_ready" }, 409);
          if (!keyBelongsToUser(rec.storage_key, auth.userId)) return json({ error: "forbidden" }, 403);
          return json(await signedViewUrl(rec.storage_key));
        } catch {
          return json({ error: "not_found" }, 404);
        }
      },
    },
  },
});
