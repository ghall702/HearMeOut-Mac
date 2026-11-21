import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { isAllowedNativeRedirect, isValidChallenge, mintNativeCode } from "./native-auth.server";

/** Called by /native/connect after the signed-in user approves the Mac app. */
export const createNativeGrant = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d) =>
    z.object({ redirectUri: z.string().max(200), codeChallenge: z.string().max(64), deviceName: z.string().max(60) }).parse(d),
  )
  .handler(async ({ data, context }) => {
    if (!isAllowedNativeRedirect(data.redirectUri)) throw new Error("This app isn't allowed to connect.");
    if (!isValidChallenge(data.codeChallenge)) throw new Error("Invalid sign-in request.");
    return mintNativeCode(context.userId, data.codeChallenge, data.deviceName);
  });
