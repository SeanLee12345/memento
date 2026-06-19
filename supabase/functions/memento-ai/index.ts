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
      case "memory.retrieve":
        result = await handleMemoryRetrieve(payload, request, auth.userId);
        break;
      case "memory.index":
        result = await handleMemoryIndex(payload, request, auth.userId);
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
    return { model, output: { text: "", noSpeech: true } };
  }
  return { model, output: { text, noSpeech: false } };
}

async function handleDeepSeekAnswer(payload: JsonRecord): Promise<JsonRecord> {
  const model = safeString(payload.model) || Deno.env.get("DEEPSEEK_MODEL") || "deepseek-v4-flash";
  const systemPrompt = requiredString(payload.systemPrompt, "systemPrompt");
  const userPrompt = requiredString(payload.userPrompt, "userPrompt");
  try {
    const apiKey = requiredEnv("DEEPSEEK_API_KEY");
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
  } catch (error) {
    const failure = normalizeFailure(error);
    if (!shouldFallbackDeepSeekAnswerToQwen(failure)) {
      throw error;
    }
    logInfo("deepseek_answer_fallback", {
      fromModel: model,
      fallback: "qwen.answer",
      kind: failure.kind,
      retryable: failure.retryable,
      message: sanitize(failure.message, 180),
    });
    const fallback = await handleQwenAnswer({
      ...payload,
      model: safeString(payload.fallbackModel) || Deno.env.get("DASHSCOPE_QA_MODEL") || "qwen3.5-flash",
      enableSearch: false,
    });
    return {
      ...fallback,
      fallbackFromModel: model,
      fallbackReason: failure.kind,
    };
  }
}

async function handleMemoryRetrieve(
  payload: JsonRecord,
  request: Request,
  userId: string,
): Promise<JsonRecord> {
  const startedAt = Date.now();
  const query = compactMemoryQuery(payload);
  const classification = await classifyMemoryText(query, "retrieval_query");
  const embeddingModel = Deno.env.get("NVIDIA_EMBEDDING_MODEL") || "nvidia/llama-nemotron-embed-1b-v2";
  const embedding = await createNVIDIAEmbedding(query, "query", embeddingModel);
  const personIds = stringArray(payload.personIds, 8);
  const activePersonIds = stringArray(payload.activePersonIds, 8);
  const boostedPersonIds = Array.from(new Set([...activePersonIds, ...personIds]));
  const sourceTypes = stringArray(payload.includeSourceTypes, 8);
  const rows = await callSupabaseRPC(request, "hybrid_memory_search", {
    p_user_id: userId,
    p_query_embedding: JSON.stringify(embedding),
    p_query_keywords: classification.keywords,
    p_query_categories: classification.categories,
    p_person_ids: boostedPersonIds,
    p_limit: Math.max(1, Math.min(integer(payload.limit, 8), 12)),
    p_min_similarity: Math.max(0, Math.min(numeric(payload.minSimilarity, 0.2), 1)),
    p_include_source_types: sourceTypes,
    p_max_sensitivity: Math.max(0, Math.min(integer(payload.maxSensitivity, 1), 2)),
  });
  const chunks = Array.isArray(rows) ? rows : [];
  logInfo("memory_retrieval", {
    queryChars: query.length,
    keywordCount: classification.keywords.length,
    categoryCount: classification.categories.length,
    chunkCount: chunks.length,
    chunkIds: chunks.slice(0, 12).map((row) => safeString((row as JsonRecord).memory_chunk_id)),
    elapsedMs: Date.now() - startedAt,
  });
  return {
    model: embeddingModel,
    promptVersion: "memoryRetrieval.v1",
    output: {
      query,
      keywords: classification.keywords,
      categories: classification.categories,
      chunks,
      latencyMs: Date.now() - startedAt,
    },
  };
}

async function handleMemoryIndex(
  payload: JsonRecord,
  request: Request,
  userId: string,
): Promise<JsonRecord> {
  const id = requiredString(payload.id, "id");
  const sourceRecordId = requiredString(payload.sourceRecordId, "sourceRecordId");
  const sourceType = requiredString(payload.sourceType, "sourceType");
  if (!["transcript_chunk", "stream_summary", "scene_context", "person_note"].includes(sourceType)) {
    throw new ProxyFailure("sourceType is invalid", { status: 400, kind: "bad_request" });
  }
  const chunkText = requiredString(payload.chunkText, "chunkText").slice(0, 6000);
  if (!isUsefulMemoryText(chunkText)) {
    return { model: "local-filter", output: { id, skipped: true, reason: "low_value" } };
  }
  const classification = await classifyMemoryText(chunkText, sourceType);
  const embeddingModel = Deno.env.get("NVIDIA_EMBEDDING_MODEL") || "nvidia/llama-nemotron-embed-1b-v2";
  const embeddingText = [safeString(payload.summaryText), chunkText].filter(Boolean).join("\n").slice(0, 7000);
  const embedding = await createNVIDIAEmbedding(embeddingText, "passage", embeddingModel);
  const row: JsonRecord = {
    id,
    owner_uid: userId,
    conversation_id: nullableString(payload.conversationId),
    stream_id: nullableString(payload.streamId),
    person_id: nullableString(payload.personId),
    source_record_id: sourceRecordId,
    source_type: sourceType,
    chunk_text: chunkText,
    summary_text: nullableString(payload.summaryText),
    keywords: mergeNormalizedTerms(classification.keywords, stringArray(payload.keywords, 16), 16),
    categories: mergeNormalizedTerms(classification.categories, stringArray(payload.categories, 12), 12),
    embedding: JSON.stringify(embedding),
    embedding_model: embeddingModel,
    start_time: nullableString(payload.startTime),
    end_time: nullableString(payload.endTime),
    importance_score: Math.max(0, Math.min(numeric(payload.importanceScore, classification.importanceScore), 1)),
    sensitivity_level: Math.max(0, Math.min(integer(payload.sensitivityLevel, classification.sensitivityLevel), 2)),
    metadata: isRecord(payload.metadata) ? payload.metadata : {},
    updated_at: new Date().toISOString(),
  };
  await upsertSupabaseRows(request, "memory_chunks", [row], "owner_uid,source_type,source_record_id");
  return {
    model: embeddingModel,
    promptVersion: "memoryIndex.v1",
    output: {
      id,
      skipped: false,
      keywords: row.keywords,
      categories: row.categories,
      sensitivityLevel: row.sensitivity_level,
    },
  };
}

type MemoryClassification = {
  keywords: string[];
  categories: string[];
  importanceScore: number;
  sensitivityLevel: number;
};

async function classifyMemoryText(text: string, sourceType: string): Promise<MemoryClassification> {
  const fallback = localMemoryClassification(text);
  try {
    const result = await handleQwenJSON("qwen.memory_classify", {
      model: Deno.env.get("DASHSCOPE_TEXT_MODEL") || Deno.env.get("DASHSCOPE_QA_MODEL") || "qwen3.5-flash",
      schema: "memory_classification",
      systemPrompt: "Classify a small private-memory excerpt. Return strict JSON only and do not infer facts not present.",
      userPrompt: [
        `Source type: ${sourceType}`,
        "Return JSON with keywords (specific entities/topics), categories (broad reusable topics), importanceScore from 0 to 1, and sensitivityLevel 0 public/routine, 1 personal, or 2 highly sensitive.",
        "Use lowercase normalized terms. Maximum 12 keywords and 8 categories.",
        "Text:",
        text.slice(0, 3500),
      ].join("\n"),
      maxTokens: 220,
      timeoutSeconds: 18,
    }, "memoryClassification.v1", 2);
    const output = result.output as JsonRecord;
    return {
      keywords: mergeNormalizedTerms(stringArray(output.keywords, 12), fallback.keywords, 12),
      categories: mergeNormalizedTerms(stringArray(output.categories, 8), fallback.categories, 8),
      importanceScore: Math.max(0, Math.min(numeric(output.importanceScore, fallback.importanceScore), 1)),
      sensitivityLevel: Math.max(0, Math.min(integer(output.sensitivityLevel, fallback.sensitivityLevel), 2)),
    };
  } catch (error) {
    logInfo("memory_classification_fallback", {
      kind: normalizeFailure(error).kind,
      textChars: text.length,
    });
    return fallback;
  }
}

async function createNVIDIAEmbedding(
  text: string,
  inputType: "query" | "passage",
  model: string,
): Promise<number[]> {
  const apiKey = requiredEnv("NVIDIA_API_KEY");
  const endpoint = Deno.env.get("NVIDIA_EMBEDDING_URL") || "https://integrate.api.nvidia.com/v1/embeddings";
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 25_000);
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        input: [text.slice(0, 7000)],
        input_type: inputType,
        encoding_format: "float",
        truncate: "END",
      }),
      signal: controller.signal,
    });
    const bodyText = await response.text();
    if (!response.ok) {
      throw new ProxyFailure(`NVIDIA embedding HTTP ${response.status}: ${sanitize(bodyText, 220)}`, {
        status: response.status >= 500 ? 502 : response.status,
        kind: "embedding_provider_http",
        retryable: response.status === 408 || response.status === 429 || response.status >= 500,
      });
    }
    const decoded = JSON.parse(bodyText) as JsonRecord;
    const data = decoded.data;
    const first = Array.isArray(data) ? data[0] as JsonRecord | undefined : undefined;
    const embedding = first?.embedding;
    if (!Array.isArray(embedding) || embedding.length !== 2048) {
      throw new ProxyFailure("NVIDIA embedding response had an unexpected dimension", {
        kind: "embedding_dimension",
      });
    }
    return embedding.map((value) => Number(value));
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new ProxyFailure("NVIDIA embedding request timed out", { status: 504, kind: "timeout", retryable: true });
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function callSupabaseRPC(request: Request, functionName: string, params: JsonRecord): Promise<unknown> {
  const response = await fetch(`${requiredEnv("SUPABASE_URL")}/rest/v1/rpc/${functionName}`, {
    method: "POST",
    headers: supabaseUserHeaders(request),
    body: JSON.stringify(params),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new ProxyFailure(`Supabase RPC ${functionName} HTTP ${response.status}: ${sanitize(text, 260)}`, {
      status: response.status >= 500 ? 502 : response.status,
      kind: "supabase_rpc",
      retryable: response.status === 408 || response.status === 429 || response.status >= 500,
    });
  }
  return text ? JSON.parse(text) : [];
}

async function upsertSupabaseRows(
  request: Request,
  table: string,
  rows: JsonRecord[],
  onConflict: string,
): Promise<void> {
  const url = new URL(`${requiredEnv("SUPABASE_URL")}/rest/v1/${table}`);
  url.searchParams.set("on_conflict", onConflict);
  const response = await fetch(url, {
    method: "POST",
    headers: {
      ...supabaseUserHeaders(request),
      "Prefer": "resolution=merge-duplicates,return=minimal",
    },
    body: JSON.stringify(rows),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new ProxyFailure(`Supabase upsert ${table} HTTP ${response.status}: ${sanitize(text, 260)}`, {
      status: response.status >= 500 ? 502 : response.status,
      kind: "supabase_upsert",
      retryable: response.status === 408 || response.status === 429 || response.status >= 500,
    });
  }
}

function supabaseUserHeaders(request: Request): Record<string, string> {
  return {
    "Authorization": request.headers.get("authorization") ?? "",
    "apikey": requiredEnv("SUPABASE_ANON_KEY"),
    "Content-Type": "application/json",
  };
}

function compactMemoryQuery(payload: JsonRecord): string {
  const sections = [
    `Request: ${requiredString(payload.query, "query")}`,
    safeString(payload.currentMode) ? `Mode: ${safeString(payload.currentMode)}` : "",
    safeString(payload.sceneContext) ? `Current context: ${safeString(payload.sceneContext)}` : "",
    stringArray(payload.presentPeople, 8).length > 0
      ? `Present people: ${stringArray(payload.presentPeople, 8).join(", ")}`
      : "",
    stringArray(payload.recentSummaries, 3).length > 0
      ? `Recent summaries: ${stringArray(payload.recentSummaries, 3).join(" | ")}`
      : "",
    Boolean(payload.exactWording) ? "Exact wording requested: true" : "",
  ];
  return sections.filter(Boolean).join("\n").slice(0, 3000);
}

function localMemoryClassification(text: string): MemoryClassification {
  const stop = new Set(["about", "after", "again", "also", "and", "are", "did", "does", "for", "from", "going", "have", "how", "last", "that", "the", "this", "time", "was", "were", "what", "when", "where", "who", "why", "with", "you", "your"]);
  const keywords = Array.from(new Set(
    text.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'-]{2,}/gu) ?? [],
  )).filter((term) => !stop.has(term)).slice(0, 12);
  const categoryMap: Record<string, string[]> = {
    travel: ["trip", "travel", "flight", "hotel", "vacation", "korea", "japan"],
    work: ["work", "job", "meeting", "project", "resume", "internship"],
    family: ["family", "mother", "father", "parent", "sister", "brother"],
    health: ["health", "doctor", "medical", "medicine", "hospital"],
    planning: ["plan", "planning", "schedule", "book", "booking", "reminder"],
  };
  const categories = Object.entries(categoryMap)
    .filter(([, terms]) => terms.some((term) => keywords.includes(term) || text.toLowerCase().includes(term)))
    .map(([category]) => category);
  const sensitivityLevel = categories.includes("health") ? 2 : categories.includes("family") ? 1 : 0;
  return { keywords, categories, importanceScore: 0.5, sensitivityLevel };
}

function isUsefulMemoryText(text: string): boolean {
  const normalized = text.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim();
  if (normalized.length < 12) return false;
  return !new Set(["no speech detected", "listening", "thank you", "okay okay", "uh um", "um uh"]).has(normalized);
}

function stringArray(value: unknown, limit: number): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((item) => safeString(item)).filter(Boolean).slice(0, limit);
}

function mergeNormalizedTerms(first: string[], second: string[], limit: number): string[] {
  return Array.from(new Set([...first, ...second].map((term) => term.toLowerCase().trim()).filter(Boolean))).slice(0, limit);
}

function nullableString(value: unknown): string | null {
  return safeString(value) || null;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function shouldFallbackDeepSeekAnswerToQwen(failure: ProxyFailure): boolean {
  return failure.kind === "empty_response"
    || failure.kind === "timeout"
    || failure.kind === "network"
    || failure.kind === "missing_secret"
    || (failure.kind === "provider_http" && failure.retryable);
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
    case "memory_classification":
      return ["keywords", "categories", "importanceScore", "sensitivityLevel"];
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
