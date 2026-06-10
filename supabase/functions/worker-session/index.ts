type WorkerKind = "face" | "speaker" | "diarization";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, error: { kind: "method_not_allowed", message: "POST required" } }, 405);
  }

  const requestId = crypto.randomUUID().slice(0, 8);
  try {
    const auth = requireAuthenticatedUser(request);
    const body = await request.json() as {
      worker?: string;
      endpoint?: string;
      ttlSeconds?: number;
      conversationSessionId?: string;
    };
    const worker = normalizeWorker(body.worker);
    const ttlSeconds = clampTTL(body.ttlSeconds ?? 900);
    const now = Math.floor(Date.now() / 1000);
    const expiresAt = now + ttlSeconds;
    const secret = requiredEnv("WORKER_TOKEN_SIGNING_SECRET");
    const tokenPayload = {
      aud: "memento-worker",
      worker,
      endpoint: body.endpoint ?? null,
      conversationSessionId: body.conversationSessionId ?? null,
      iat: now,
      exp: expiresAt,
      nonce: crypto.randomUUID(),
    };
    const token = await signToken(tokenPayload, secret);

    console.log(JSON.stringify({
      event: "worker_session_issued",
      requestId,
      worker,
      authRole: auth.role,
      ttlSeconds,
      expiresAt,
      hasEndpoint: Boolean(body.endpoint),
      hasConversationSessionId: Boolean(body.conversationSessionId),
    }));

    return jsonResponse({
      ok: true,
      source: "supabase_edge",
      worker,
      token,
      tokenType: "MementoWorkerHMAC",
      authHeader: `Bearer ${token}`,
      expiresAt,
      expiresIn: ttlSeconds,
    }, 200);
  } catch (error) {
    const status = error instanceof WorkerSessionError ? error.status : 500;
    const kind = error instanceof WorkerSessionError ? error.kind : "unexpected";
    const message = error instanceof Error ? error.message : String(error);
    console.log(JSON.stringify({
      event: "worker_session_failed",
      requestId,
      status,
      kind,
      message: sanitize(message, 180),
    }));
    return jsonResponse({
      ok: false,
      source: "supabase_edge",
      error: { kind, message: sanitize(message, 260) },
    }, status);
  }
});

class WorkerSessionError extends Error {
  status: number;
  kind: string;

  constructor(message: string, status: number, kind: string) {
    super(message);
    this.status = status;
    this.kind = kind;
  }
}

function normalizeWorker(value: unknown): WorkerKind {
  switch (typeof value === "string" ? value.trim().toLowerCase() : "") {
    case "face":
      return "face";
    case "speaker":
      return "speaker";
    case "diarization":
      return "diarization";
    default:
      throw new WorkerSessionError("worker must be face, speaker, or diarization", 400, "bad_request");
  }
}

function clampTTL(value: number): number {
  if (!Number.isFinite(value)) return 900;
  return Math.min(1800, Math.max(60, Math.trunc(value)));
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new WorkerSessionError(`${name} is not configured`, 500, "missing_secret");
  }
  return value;
}

function requireAuthenticatedUser(request: Request): { userId: string; role: string } {
  const header = request.headers.get("authorization") ?? "";
  if (!header.toLowerCase().startsWith("bearer ")) {
    throw new WorkerSessionError("Supabase user JWT is required", 401, "unauthenticated");
  }
  const token = header.slice("bearer ".length).trim();
  const payload = decodeJWTPayload(token);
  const userId = safeString(payload.sub);
  const role = safeString(payload.role);
  if (!userId || role === "anon") {
    throw new WorkerSessionError("Supabase authenticated user JWT is required", 401, "unauthenticated");
  }
  return { userId, role };
}

function decodeJWTPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length < 2) {
    throw new WorkerSessionError("Authorization token is not a JWT", 401, "unauthenticated");
  }
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parts[1].length / 4) * 4, "=");
    return JSON.parse(atob(padded)) as Record<string, unknown>;
  } catch {
    throw new WorkerSessionError("Authorization token payload could not be decoded", 401, "unauthenticated");
  }
}

function safeString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

async function signToken(payload: Record<string, unknown>, secret: string): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const headerPart = base64URL(JSON.stringify(header));
  const payloadPart = base64URL(JSON.stringify(payload));
  const data = `${headerPart}.${payloadPart}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return `${data}.${base64URL(new Uint8Array(signature))}`;
}

function base64URL(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function sanitize(value: string, maxLength: number): string {
  const redacted = value.replace(/[A-Za-z0-9_=-]{32,}/g, "[redacted]");
  return redacted.length > maxLength ? `${redacted.slice(0, maxLength).trim()}...` : redacted;
}
