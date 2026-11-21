import { createFileRoute } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { useEffect, useState } from "react";
import { Laptop, Loader2, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Logo } from "@/components/hmo/Logo";
import { lovable } from "@/integrations/lovable";
import { supabase } from "@/integrations/supabase/client";
import { ALLOWED_EMAILS } from "@/lib/hmo-core";
import { createNativeGrant } from "@/lib/native-auth.functions";

// Approval page opened by the Hear Me Out Mac app (ASWebAuthenticationSession). On approval it
// redirects to hearmeout://auth/callback with a short-lived, PKCE-bound authorisation code.
export const Route = createFileRoute("/native/connect")({
  ssr: false,
  head: () => ({ meta: [{ title: "Connect the Mac app — Hear Me Out" }, { name: "robots", content: "noindex" }] }),
  component: ConnectNative,
});

const PENDING_KEY = "hmo-native-connect";
const REDIRECT = "hearmeout://auth/callback";
type Pending = { redirectUri: string; state: string; challenge: string; device: string };

function readPending(): Pending | null {
  const q = new URLSearchParams(window.location.search);
  const redirectUri = q.get("redirect_uri");
  const state = q.get("state");
  const challenge = q.get("code_challenge");
  if (redirectUri && state && challenge && q.get("code_challenge_method") === "S256") {
    const p = { redirectUri, state, challenge, device: (q.get("device_name") ?? "Mac").slice(0, 60) };
    sessionStorage.setItem(PENDING_KEY, JSON.stringify(p));
    return p;
  }
  try {
    return JSON.parse(sessionStorage.getItem(PENDING_KEY) ?? "null") as Pending | null;
  } catch {
    return null;
  }
}

function ConnectNative() {
  const grant = useServerFn(createNativeGrant);
  const [pending, setPending] = useState<Pending | null>(null);
  const [email, setEmail] = useState<string | null>(null);
  const [phase, setPhase] = useState<"checking" | "signin" | "approve" | "working" | "done" | "error">("checking");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const p = readPending();
    setPending(p);
    if (!p || p.redirectUri !== REDIRECT || !/^[\w-]{16,128}$/.test(p.state) || !/^[A-Za-z0-9_-]{43}$/.test(p.challenge)) {
      setPhase("error");
      setError("This link is incomplete. In the Hear Me Out Mac app, choose Sign in with Google again.");
      return;
    }
    supabase.auth.getUser().then(({ data }) => {
      const e = data.user?.email?.toLowerCase() ?? null;
      if (data.user && e && ALLOWED_EMAILS.includes(e)) {
        setEmail(e);
        setPhase("approve");
      } else {
        if (data.user) {
          void supabase.auth.signOut();
          setError("That Google account isn't authorised for Hear Me Out.");
        }
        setPhase("signin");
      }
    });
  }, []);

  const finish = (params: Record<string, string>) => {
    if (!pending) return;
    sessionStorage.removeItem(PENDING_KEY);
    const q = new URLSearchParams({ ...params, state: pending.state });
    setPhase("done");
    window.location.replace(`${pending.redirectUri}?${q.toString()}`);
  };

  const signIn = async (switchAccount = false) => {
    setPhase("working");
    if (switchAccount) await supabase.auth.signOut();
    const r = await lovable.auth.signInWithOAuth("google", {
      redirect_uri: `${window.location.origin}/native/connect`,
      extraParams: { prompt: "select_account" },
    });
    if (r.error) {
      setError(/authori|not allowed|Database error/i.test(r.error.message) ? "That Google account isn't authorised for Hear Me Out." : r.error.message);
      setPhase("signin");
      return;
    }
    if (r.redirected) return;
    window.location.reload();
  };

  const approve = async () => {
    setPhase("working");
    try {
      const { code } = await grant({ data: { redirectUri: pending!.redirectUri, codeChallenge: pending!.challenge, deviceName: pending!.device } });
      finish({ code });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not connect the Mac app.");
      setPhase("approve");
    }
  };

  return (
    <div className="grid min-h-dvh place-items-center px-5 py-10">
      <div className="w-full max-w-md animate-rise rounded-[2rem] border bg-card p-7 shadow-soft">
        <Logo />
        <h1 className="mt-8 text-2xl font-semibold">Connect Hear Me Out for Mac</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {pending?.device ? `“${pending.device}”` : "The Mac app"} will be able to record voice notes to your account and list your recordings. It never sees your password, and you can disconnect it in Settings → API keys.
        </p>
        {error && <p className="mt-4 rounded-2xl bg-destructive/10 px-4 py-3 text-sm text-destructive">{error}</p>}
        {phase === "checking" || phase === "working" ? (
          <div className="mt-8 grid place-items-center"><Loader2 className="size-6 animate-spin text-muted-foreground" /></div>
        ) : phase === "done" ? (
          <p className="mt-8 text-sm text-muted-foreground">Done — you can return to the Hear Me Out app.</p>
        ) : phase === "signin" ? (
          <div className="mt-8 space-y-3">
            <Button className="h-12 w-full rounded-full" variant="outline" onClick={() => signIn(false)}>Continue with Google</Button>
            <Button className="w-full rounded-full" variant="ghost" onClick={() => finish({ error: "access_denied" })}>Cancel</Button>
          </div>
        ) : phase === "approve" ? (
          <div className="mt-6 space-y-3">
            <div className="flex items-center gap-3 rounded-2xl bg-muted/60 px-4 py-3 text-sm">
              <ShieldCheck className="size-5 text-primary" />
              <span className="min-w-0 truncate">Signed in as <strong>{email}</strong></span>
            </div>
            <Button className="h-12 w-full rounded-full" variant="hero" onClick={approve}><Laptop /> Connect this Mac</Button>
            <div className="flex gap-2">
              <Button className="flex-1 rounded-full" variant="outline" onClick={() => signIn(true)}>Use a different account</Button>
              <Button className="flex-1 rounded-full" variant="ghost" onClick={() => finish({ error: "access_denied" })}>Cancel</Button>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}
