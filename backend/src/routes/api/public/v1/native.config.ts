import { createFileRoute } from "@tanstack/react-router";
import { json } from "@/lib/api-http.server";

// GET /api/public/v1/native/config — lets the Mac app detect that native sign-in is deployed.
export const Route = createFileRoute("/api/public/v1/native/config")({
  server: { handlers: { GET: async () => json({ enabled: true, redirectUris: ["hearmeout://auth/callback"], pkce: ["S256"] }) } },
});
