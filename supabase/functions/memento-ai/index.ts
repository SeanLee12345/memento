type JsonRecord = Record<string, unknown>;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const defaultDashScopeCompatibleBaseURL = "https://dashscope-us.aliyuncs.com/compatible-mode/v1";
const defaultDeepSeekBaseURL = "https://api.deepseek.com/v1";

class ProxyFailure extends Error {
  status: number;
  kind: string;
  retryable: boolean;

  constructor(message: string, options: { status?: number; kind?: string; retryable?: boolean } = {}) {
    super(message);
    this.status = options.status ?? 500;
    this.kind = options.kind ?? "proxy_error";
    this.retryable = options.retryable ?? false;
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, error: { kind: "method_not_allowed", message: "POST required" } }, 405);
  }

  const startedAt = Date.now();
  const requestId = crypto.randomUUID().slice(0, 8);
  try {
    const auth = requireAuthenticatedUser(request);
    const bodyText = await request.text();
    const body = JSON.parse(bodyText) as { operation?: string; payload?: JsonRecord; requestId?: string };
    const operation = String(body.operation ?? "");
    const payload = (body.payload ?? {}) as JsonRecord;
    const effectiveRequestId = body.requestId ?? requestId;

    logInfo("start", {
      requestId: effectiveRequestId,
      operation,
      authRole: auth.role,
      requestBytes: bodyText.length,
      model: safeString(payload.model),
      promptChars: promptCharCount(payload),
      audioBytes: base64ByteEstimate(safeString(payload.wavBase64)),
      imageCount: Array.isArray(payload.imageDataUrls) ? payload.imageDataUrls.length : undefined,
    });

    let result: JsonRecord;
    switch (operation) {
      case "qwen.answer":
        result = await handleQwenAnswer(payload);
        break;
      case "qwen.scene_context":
        result = await handleQwenJSON(operation, payload, "sceneContext.v1", 2);
        break;
      case "qwen.stream_summary":
        result = await handleQwenJSON(operation, payload, "streamSummary.v2", 3);
        break;
      case "qwen.activity_mode":
        result = await handleQwenJSON(operation, payload, "activityMode.v1", 2);
        break;
      case "qwen.live_asr":
        result = await handleQwenLiveASR(payload);
        break;
      case "deepseek.answer":
        result = await handleDeepSeekAnswer(payload);
        break;
      default:
        throw new ProxyFailure(`Unsupported operation: ${operation}`, { status: 400, kind: "unsupported_operation" });
    }

    logInfo("success", {
      requestId: effectiveRequestId,
      operation,
      elapsedMs: Date.now() - startedAt,
      model: safeString(result.model),
      outputChars: outputCharCount(result.output),
    });
    return jsonResponse({ ok: true, operation, source: "supabase_edge", ...result }, 200);
  } catch (error) {
    const failure = normalizeFailure(error);
    logInfo("failure", {
      requestId,
      elapsedMs: Date.now() - startedAt,
      status: failure.status,
      kind: failure.kind,
      retryable: failure.retryable,
      message: sanitize(failure.message, 220),
    });
    return jsonResponse({
      ok: false,
      source: "supabase_edge",
      error: {
        kind: failure.kind,
        message: sanitize(failure.message, 360),
        retryable: failure.retryable,
      },
    }, failure.status);
  }
});

async function handleQwenAnswer(payload: JsonRecord): Promise<JsonRecord> {
  const apiKey = requiredEnv("DASHSCOPE_API_KEY");
  const model = safeString(payload.model) || Deno.env.get("DASHSCOPE_QA_MODEL") || "qwen3.5-flash";
  const systemPrompt = requiredString(payload.systemPrompt, "systemPrompt");
  const userPrompt = requiredString(payload.userPrompt, "userPrompt");
  const enableSearch = Boolean(payload.enableSearch);
  const body = chatBody({
    model,
    systemPrompt,
    userPrompt,
    temperature: numeric(payload.temperature, 0.1),
    maxTokens: integer(payload.maxTokens, 80),
    enableThinking: false,
    enableSearch,
    searchStrategy: safeString(payload.searchStrategy) || Deno.env.get("DASHSCOPE_SEARCH_STRATEGY") || "turbo",
  });
  const response = await callOpenAICompatibleChat(dashScopeBaseURL(), apiKey, body, integer(payload.timeoutSeconds, 25) * 1000);
  const text = extractChatText(response).trim();
  if (!text) {
    throw new ProxyFailure("Qwen returned an empty answer", { kind: "empty_response", retryable: true });
  }
  if (payload.schema === "live_trigger") {
    return { model, output: parseJSONWithRecovery(text) };
  }
  return {
    model,
    output: {
      text,
      usedWebSearch: enableSearch,
      sources: [],
    },
  };
}

async function handleQwenJSON(
  operation: string,
  payload: JsonRecord,
  promptVersion: string,
  maxAttempts: number,
): Promise<JsonRecord> {
  const apiKey = requiredEnv("DASHSCOPE_API_KEY");
  const systemPrompt = requiredString(payload.systemPrompt, "systemPrompt");
  const originalUserPrompt = requiredString(payload.userPrompt, "userPrompt");
  const schema = safeString(payload.schema);
  const imageDataUrls = Array.isArray(payload.imageDataUrls)
    ? payload.imageDataUrls.map((value) => String(value)).filter(Boolean).slice(0, 4)
    : [];
  const model = safeString(payload.model) || defaultQwenJSONModel(operation, imageDataUrls.length > 0);

  let userPrompt = originalUserPrompt;
  let lastFailure: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const body = multimodalChatBody({
      model,
      systemPrompt,
      userPrompt,
      imageDataUrls,
      temperature: numeric(payload.temperature, operation === "qwen.activity_mode" ? 0 : 0.1),
      maxTokens: integer(payload.maxTokens, operation === "qwen.stream_summary" ? 320 : 800),
      enableThinking: false,
    });
    try {
      const response = await callOpenAICompatibleChat(
        dashScopeBaseURL(),
        apiKey,
        body,
        integer(payload.timeoutSeconds, operation === "qwen.stream_summary" ? 45 : 20) * 1000,
      );
      const text = extractChatText(response).trim();
      if (!text) {
        throw new ProxyFailure("Qwen returned empty JSON content", { kind: "empty_response", retryable: true });
      }
      const parsed = parseJSONWithRecovery(text);
      return {
        model,
        promptVersion: attempt === 1 ? promptVersion : `${promptVersion}.strictJSONRetry`,
        output: parsed,
      };
    } catch (error) {
      lastFailure = error;
      const failure = normalizeFailure(error);
      logInfo("qwen_json_attempt_failed", {
        operation,
        attempt,
        maxAttempts,
        model,
        promptVersion: attempt === 1 ? promptVersion : `${promptVersion}.strictJSONRetry`,
        kind: failure.kind,
        retryable: failure.retryable || failure.kind === "malformed_json",
        message: sanitize(failure.message, 220),
      });
      if (attempt >= maxAttempts || !(failure.retryable || failure.kind === "malformed_json")) {
        throw error;
      }
      userPrompt = strictJSONRetryPrompt(originalUserPrompt, requiredKeysForSchema(schema, operation));
      await sleep(250 * attempt);
    }
  }
  throw lastFailure;
}

async function handleQwenLiveASR(payload: JsonRecord): Promise<JsonRecord> {
  const apiKey = requiredEnv("DASHSCOPE_API_KEY");
  const model = safeString(payload.model) || Deno.env.get("DASHSCOPE_ASR_MODEL") || "qwen3-asr-flash-us";
  const wavBase64 = requiredString(payload.wavBase64, "wavBase64");
  if (base64ByteEstimate(wavBase64) > 1_200_000) {
    throw new ProxyFailure("ASR chunk is too large", { status: 413, kind: "payload_too_large" });
  }
  const body = {
    model,
    messages: [{
      role: "user",
      content: [{
        type: "input_audio",
        input_audio: {
          data: `data:audio/wav;base64,${wavBase64}`,
          format: "wav",
        },
      }],
    }],
  };
  const response = await callOpenAICompatibleChat(dashScopeBaseURL(), apiKey, body, integer(payload.timeoutSeconds, 35) * 1000);
  const text = extractTranscript(response).trim();
  if (!text) {
    throw new ProxyFailure("Qwen ASR returned an empty transcript", { kind: "empty_response", retryable: true });
  }
  return { model, output: { text } };
}

async function handleDeepSeekAnswer(payload: JsonRecord): Promise<JsonRecord> {
  const apiKey = requiredEnv("DEEPSEEK_API_KEY");
  const model = safeString(payload.model) || Deno.env.get("DEEPSEEK_MODEL") || "deepseek-v4-flash";
  const systemPrompt = requiredString(payload.systemPrompt, "systemPrompt");
  const userPrompt = requiredString(payload.userPrompt, "userPrompt");
  const body = chatBody({
    model,
    systemPrompt,
    userPrompt,
    temperature: numeric(payload.temperature, 0.2),
    maxTokens: integer(payload.maxTokens, 90),
  });
  const response = await callOpenAICompatibleChat(
    Deno.env.get("DEEPSEEK_BASE_URL") || defaultDeepSeekBaseURL,
    apiKey,
    body,
    integer(payload.timeoutSeconds, 18) * 1000,
  );
  const text = extractChatText(response).trim();
  if (!text) {
    throw new ProxyFailure("DeepSeek returned an empty answer", { kind: "empty_response", retryable: true });
  }
  return { model, output: { text } };
}

async function callOpenAICompatibleChat(
  baseURL: string,
  apiKey: string,
  body: unknown,
  timeoutMs: number,
): Promise<JsonRecord> {
  const endpoint = chatCompletionsURL(baseURL);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    const text = await response.text();
    if (!response.ok) {
      throw new ProxyFailure(`provider HTTP ${response.status}: ${sanitize(text, 260)}`, {
        status: response.status >= 500 ? 502 : response.status,
        kind: "provider_http",
        retryable: response.status === 408 || response.status === 429 || response.status >= 500,
      });
    }
    try {
      return JSON.parse(text) as JsonRecord;
    } catch {
      throw new ProxyFailure("provider returned non-JSON response", { kind: "provider_non_json", retryable: true });
    }
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new ProxyFailure("provider request timed out", { status: 504, kind: "timeout", retryable: true });
    }
    if (error instanceof ProxyFailure) {
      throw error;
    }
    throw new ProxyFailure(error instanceof Error ? error.message : String(error), { kind: "network", retryable: true });
  } finally {
    clearTimeout(timeout);
  }
}

function chatBody(options: {
  model: string;
  systemPrompt: string;
  userPrompt: string;
  temperature: number;
  maxTokens: number;
  enableThinking?: boolean;
  enableSearch?: boolean;
  searchStrategy?: string;
}): JsonRecord {
  const body: JsonRecord = {
    model: options.model,
    messages: [
      { role: "system", content: options.systemPrompt },
      { role: "user", content: options.userPrompt },
    ],
    temperature: options.temperature,
    max_tokens: options.maxTokens,
  };
  if (options.enableThinking !== undefined) body.enable_thinking = options.enableThinking;
  if (options.enableSearch) {
    body.enable_search = true;
    body.search_options = {
      search_strategy: options.searchStrategy || "turbo",
      forced_search: true,
    };
  }
  return body;
}

function multimodalChatBody(options: {
  model: string;
  systemPrompt: string;
  userPrompt: string;
  imageDataUrls: string[];
  temperature: number;
  maxTokens: number;
  enableThinking: boolean;
}): JsonRecord {
  const userContent: JsonRecord[] = [{ type: "text", text: options.userPrompt }];
  for (const url of options.imageDataUrls) {
    userContent.push({ type: "image_url", image_url: { url } });
  }
  return {
    model: options.model,
    messages: [
      { role: "system", content: [{ type: "text", text: options.systemPrompt }] },
      { role: "user", content: userContent },
    ],
    temperature: options.temperature,
    max_tokens: options.maxTokens,
    enable_thinking: options.enableThinking,
  };
}

function extractChatText(response: JsonRecord): string {
  const choices = response.choices;
  if (Array.isArray(choices)) {
    const first = choices[0] as JsonRecord | undefined;
    const message = first?.message as JsonRecord | undefined;
    const content = message?.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      return content.map((item) => {
        const record = item as JsonRecord;
        return safeString(record.text) || safeString(record.transcript);
      }).filter(Boolean).join(" ");
    }
  }
  const output = response.output as JsonRecord | undefined;
  if (output) {
    const outputChoices = output.choices;
    if (Array.isArray(outputChoices)) {
      const first = outputChoices[0] as JsonRecord | undefined;
      const message = first?.message as JsonRecord | undefined;
      if (typeof message?.content === "string") return message.content;
    }
    if (typeof output.text === "string") return output.text;
  }
  return "";
}

function extractTranscript(response: JsonRecord): string {
  const chatText = extractChatText(response);
  if (chatText) return chatText;
  const output = response.output as JsonRecord | undefined;
  const transcripts = output?.transcripts;
  if (Array.isArray(transcripts)) {
    return transcripts.map((item) => safeString((item as JsonRecord).text)).filter(Boolean).join(" ");
  }
  return "";
}

function parseJSONWithRecovery(text: string): JsonRecord {
  const jsonText = extractJSONObject(text);
  for (const candidate of [jsonText, repairCommonJSONIssues(jsonText)]) {
    try {
      return JSON.parse(candidate) as JsonRecord;
    } catch {
      // try next candidate
    }
  }
  throw new ProxyFailure("model output was not recoverable JSON", { kind: "malformed_json", retryable: true });
}

function extractJSONObject(text: string): string {
  let trimmed = text.trim();
  if (trimmed.startsWith("```")) {
    const lines = trimmed.split("\n");
    lines.shift();
    trimmed = lines.join("\n");
    const lastFence = trimmed.lastIndexOf("```");
    if (lastFence >= 0) trimmed = trimmed.slice(0, lastFence);
  }
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end >= start) {
    return trimmed.slice(start, end + 1).trim();
  }
  return trimmed;
}

function repairCommonJSONIssues(text: string): string {
  return text
    .replace(/,\s*([}\]])/g, "$1")
    .replace(/[“”]/g, "\"")
    .replace(/[‘’]/g, "'");
}

function strictJSONRetryPrompt(originalPrompt: string, keys: string[]): string {
  return [
    "Your previous answer was rejected because it was not valid JSON for the required schema.",
    "",
    "Retry with STRICT JSON ONLY:",
    "- Return only one JSON object.",
    "- No markdown fence.",
    "- No prose before or after JSON.",
    "- No trailing commas.",
    "- Use double quotes for all keys and string values.",
    `- Include every required key exactly: ${keys.join(", ")}.`,
    "",
    "Original task:",
    originalPrompt,
  ].join("\n");
}

function requiredKeysForSchema(schema: string, operation: string): string[] {
  switch (schema) {
    case "name_address":
      return ["intent", "displayName", "personId", "confidence", "evidence"];
    case "activity_mode":
      return ["mode", "specific_activity", "confidence", "reason"];
    case "stream_summary":
      return ["summary", "who", "where", "what", "when", "why", "how", "people", "keyMoments", "outline", "confidence"];
    case "scene_context":
      return ["who", "where", "what", "when", "why", "how", "interactionStyle", "summary", "confidence", "evidence"];
    default:
      return requiredKeysForOperation(operation);
  }
}

function requiredKeysForOperation(operation: string): string[] {
  switch (operation) {
    case "qwen.stream_summary":
      return ["summary", "who", "where", "what", "when", "why", "how", "people", "keyMoments", "outline", "confidence"];
    case "qwen.activity_mode":
      return ["mode", "specific_activity", "confidence", "reason"];
    case "qwen.scene_context":
      return ["who", "where", "what", "when", "why", "how", "interactionStyle", "summary", "confidence", "evidence"];
    default:
      return ["result"];
  }
}

function dashScopeBaseURL(): string {
  return Deno.env.get("DASHSCOPE_BASE_URL") || Deno.env.get("DASHSCOPE_QA_BASE_URL") || defaultDashScopeCompatibleBaseURL;
}

function defaultQwenJSONModel(operation: string, hasImages: boolean): string {
  if (operation === "qwen.scene_context" && hasImages) {
    return Deno.env.get("DASHSCOPE_VL_MODEL") || Deno.env.get("QWEN_VL_MODEL") || "qwen3-vl-flash-us";
  }
  return Deno.env.get("DASHSCOPE_TEXT_MODEL")
    || Deno.env.get("QWEN_TEXT_MODEL")
    || Deno.env.get("DASHSCOPE_QA_MODEL")
    || "qwen3.5-flash";
}

function chatCompletionsURL(baseURL: string): string {
  const trimmed = baseURL.replace(/\/+$/, "");
  if (trimmed.endsWith("/chat/completions")) return trimmed;
  return `${trimmed}/chat/completions`;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new ProxyFailure(`${name} is not configured`, { status: 500, kind: "missing_secret" });
  }
  return value;
}

function requireAuthenticatedUser(request: Request): { userId: string; role: string } {
  const header = request.headers.get("authorization") ?? "";
  if (!header.toLowerCase().startsWith("bearer ")) {
    throw new ProxyFailure("Supabase user JWT is required", { status: 401, kind: "unauthenticated" });
  }
  const token = header.slice("bearer ".length).trim();
  const payload = decodeJWTPayload(token);
  const userId = safeString(payload.sub);
  const role = safeString(payload.role);
  if (!userId || role === "anon") {
    throw new ProxyFailure("Supabase authenticated user JWT is required", { status: 401, kind: "unauthenticated" });
  }
  return { userId, role };
}

function decodeJWTPayload(token: string): JsonRecord {
  const parts = token.split(".");
  if (parts.length < 2) {
    throw new ProxyFailure("Authorization token is not a JWT", { status: 401, kind: "unauthenticated" });
  }
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parts[1].length / 4) * 4, "=");
    return JSON.parse(atob(padded)) as JsonRecord;
  } catch {
    throw new ProxyFailure("Authorization token payload could not be decoded", { status: 401, kind: "unauthenticated" });
  }
}

function requiredString(value: unknown, name: string): string {
  const text = safeString(value);
  if (!text) {
    throw new ProxyFailure(`${name} is required`, { status: 400, kind: "bad_request" });
  }
  return text;
}

function safeString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function numeric(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function integer(value: unknown, fallback: number): number {
  return Math.trunc(numeric(value, fallback));
}

function promptCharCount(payload: JsonRecord): number | undefined {
  const parts = [payload.userPrompt, payload.systemPrompt].filter((value) => typeof value === "string") as string[];
  if (parts.length === 0) return undefined;
  return parts.reduce((sum, item) => sum + item.length, 0);
}

function base64ByteEstimate(value: string): number | undefined {
  if (!value) return undefined;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor(value.length * 3 / 4) - padding);
}

function outputCharCount(output: unknown): number | undefined {
  if (!output) return undefined;
  return JSON.stringify(output).length;
}

function normalizeFailure(error: unknown): ProxyFailure {
  if (error instanceof ProxyFailure) return error;
  if (error instanceof SyntaxError) {
    return new ProxyFailure("request JSON could not be parsed", { status: 400, kind: "bad_json" });
  }
  if (error instanceof Error) {
    return new ProxyFailure(error.message, { kind: "unexpected" });
  }
  return new ProxyFailure(String(error), { kind: "unexpected" });
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

function logInfo(event: string, details: JsonRecord): void {
  console.log(JSON.stringify({ event, ...details }));
}

function sanitize(value: string, maxLength: number): string {
  const redacted = value
    .replace(/bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [redacted]")
    .replace(/"api[_-]?key"\s*:\s*"[^"]+"/gi, "\"api_key\":\"[redacted]\"")
    .replace(/[A-Za-z0-9_=-]{32,}/g, "[redacted]");
  return redacted.length > maxLength ? `${redacted.slice(0, maxLength).trim()}...` : redacted;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
