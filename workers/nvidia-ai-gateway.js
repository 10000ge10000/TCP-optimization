const DEFAULT_SUB2API_BASE_URL = "https://api.910501.xyz/v1";
const DEFAULT_SUB2API_MODEL = "gpt-5.5";
const DEFAULT_NVIDIA_BASE_URL = "https://integrate.api.nvidia.com/v1";

const PUBLIC_MODEL_ALIASES = new Set([
  "tcp-tune-default",
  "gpt-5.5",
  "minimaxai/minimax-m3",
  "moonshotai/kimi-k2.6",
  "minimaxai/minimax-m2.7",
  "z-ai/glm-5.1",
]);
const ALLOWED_BODY_FIELDS = new Set(["model", "messages", "temperature", "max_tokens", "stream"]);
const ALLOWED_MESSAGE_FIELDS = new Set(["role", "content"]);
const ALLOWED_ROLES = new Set(["system", "user", "assistant"]);
const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);

const MAX_BODY_BYTES = 64 * 1024;
const MAX_RESPONSE_BYTES = 256 * 1024;
const BODY_READ_TIMEOUT_MS = 5_000;
const GLOBAL_DEADLINE_MS = 45_000;
const UPSTREAM_TIMEOUT_MS = 30_000;
const MAX_MESSAGES = 16;
const MAX_MESSAGE_CHARS = 12_000;
const MAX_TOTAL_MESSAGE_CHARS = 32_000;
const MAX_TOKENS_LIMIT = 1_024;

function jsonResponse(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...extraHeaders,
    },
  });
}

function errorResponse(code, message, status, extraHeaders) {
  return jsonResponse({ error: { code, message } }, status, extraHeaders);
}

function parsePositiveInt(value, fallback, maximum) {
  if (value === undefined || value === null || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) return fallback;
  return Math.min(parsed, maximum);
}

async function sha256Hex(value) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function constantTimeTokenMatch(actual, expected) {
  if (!actual || !expected) return false;
  const [actualHash, expectedHash] = await Promise.all([sha256Hex(actual), sha256Hex(expected)]);
  let difference = actualHash.length ^ expectedHash.length;
  for (let index = 0; index < Math.max(actualHash.length, expectedHash.length); index += 1) {
    difference |= (actualHash.charCodeAt(index) || 0) ^ (expectedHash.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function bearerToken(request) {
  const authorization = request.headers.get("authorization") || "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
}

async function authenticateAndIdentify(request, env) {
  const token = bearerToken(request);
  if (env.AI_GATEWAY_CLIENT_TOKEN && !(await constantTimeTokenMatch(token, env.AI_GATEWAY_CLIENT_TOKEN))) {
    return { error: errorResponse("unauthorized", "authentication required", 401) };
  }
  if (token) return { subject: `token:${await sha256Hex(token)}` };
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  return { subject: `ip:${await sha256Hex(ip)}` };
}

async function readLimitedBody(request, maxBytes = MAX_BODY_BYTES, timeoutMs = BODY_READ_TIMEOUT_MS) {
  const declaredLength = request.headers.get("content-length");
  if (declaredLength !== null) {
    if (!/^\d+$/.test(declaredLength)) throw Object.assign(new Error("invalid content length"), { status: 400 });
    if (Number(declaredLength) > maxBytes) throw Object.assign(new Error("request body too large"), { status: 413 });
  }
  if (!request.body) throw Object.assign(new Error("request body is required"), { status: 400 });

  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(Object.assign(new Error("request body timeout"), { status: 408 })), timeoutMs);
  });
  try {
    while (true) {
      const { done, value } = await Promise.race([reader.read(), timeout]);
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel("body limit exceeded");
        throw Object.assign(new Error("request body too large"), { status: 413 });
      }
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel("request body rejected").catch(() => undefined);
    throw error;
  } finally {
    clearTimeout(timer);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function sanitizeChatBody(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "request body must be a JSON object" };
  const unknownField = Object.keys(body).find((field) => !ALLOWED_BODY_FIELDS.has(field));
  if (unknownField) return { error: `unknown field: ${unknownField}` };
  if (typeof body.model !== "string" || !PUBLIC_MODEL_ALIASES.has(body.model)) return { error: "model is not allowed" };
  if (!Array.isArray(body.messages) || body.messages.length < 1 || body.messages.length > MAX_MESSAGES) {
    return { error: `messages must contain 1-${MAX_MESSAGES} items` };
  }
  let totalChars = 0;
  const messages = [];
  for (const message of body.messages) {
    if (!message || typeof message !== "object" || Array.isArray(message)) return { error: "each message must be an object" };
    const unknownMessageField = Object.keys(message).find((field) => !ALLOWED_MESSAGE_FIELDS.has(field));
    if (unknownMessageField) return { error: `unknown message field: ${unknownMessageField}` };
    if (!ALLOWED_ROLES.has(message.role)) return { error: "message role is not allowed" };
    if (typeof message.content !== "string" || message.content.length > MAX_MESSAGE_CHARS) {
      return { error: `message content must be a string no longer than ${MAX_MESSAGE_CHARS} characters` };
    }
    totalChars += message.content.length;
    if (totalChars > MAX_TOTAL_MESSAGE_CHARS) return { error: `message content exceeds ${MAX_TOTAL_MESSAGE_CHARS} total characters` };
    messages.push({ role: message.role, content: message.content });
  }
  const maxTokens = body.max_tokens === undefined ? 256 : body.max_tokens;
  if (!Number.isSafeInteger(maxTokens) || maxTokens < 1 || maxTokens > MAX_TOKENS_LIMIT) {
    return { error: `max_tokens must be an integer between 1 and ${MAX_TOKENS_LIMIT}` };
  }
  if (body.temperature !== undefined && body.temperature !== 0) return { error: "temperature must be 0" };
  if (body.stream !== undefined && body.stream !== false) return { error: "streaming is not supported" };
  return { body: { model: body.model, messages, temperature: 0, max_tokens: maxTokens, stream: false } };
}

function configuredUpstreams(env) {
  const upstreams = [];
  const sub2apiKey = env.SUB2API_API_KEY || env.TCP_TUNE_SUB2API_API_KEY;
  if (sub2apiKey) {
    upstreams.push({
      id: "sub2api-primary",
      baseUrl: (env.SUB2API_BASE_URL || DEFAULT_SUB2API_BASE_URL).replace(/\/+$/, ""),
      apiKey: sub2apiKey,
      model: env.SUB2API_MODEL || DEFAULT_SUB2API_MODEL,
    });
  }
  [env.NVIDIA_API_KEY, env.NVIDIA_API_KEY_2].filter(Boolean).forEach((apiKey, index) => {
    upstreams.push({
      id: `nvidia-${index + 1}`,
      baseUrl: (env.NVIDIA_BASE_URL || DEFAULT_NVIDIA_BASE_URL).replace(/\/+$/, ""),
      apiKey,
      model: null,
    });
  });
  return upstreams;
}

async function durableJson(namespace, name, path, init) {
  const id = namespace.idFromName(name);
  const response = await namespace.get(id).fetch(`https://durable.internal${path}`, init);
  const data = await response.json().catch(() => ({}));
  return { response, data };
}

async function acquireLease(env, subject) {
  return durableJson(env.SUBJECT_LIMITER, subject, "/acquire", { method: "POST" });
}

async function releaseLease(env, subject, leaseId) {
  if (!leaseId) return;
  await durableJson(env.SUBJECT_LIMITER, subject, "/release", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ lease_id: leaseId }),
  }).catch(() => undefined);
}

async function circuitPermit(env, upstreamId) {
  return durableJson(env.UPSTREAM_CIRCUIT, upstreamId, "/permit", { method: "POST" });
}

async function circuitResult(env, upstreamId, success, retryable) {
  await durableJson(env.UPSTREAM_CIRCUIT, upstreamId, "/result", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ success, retryable }),
  }).catch(() => undefined);
}

async function fetchWithDeadline(url, init, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function readLimitedResponse(response) {
  if (!response.body) throw new Error("empty upstream response");
  const declaredLength = Number(response.headers.get("content-length") || 0);
  if (declaredLength > MAX_RESPONSE_BYTES) throw new Error("upstream response too large");
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_RESPONSE_BYTES) {
      await reader.cancel("response limit exceeded");
      throw new Error("upstream response too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function cleanSuccessPayload(payload, publicModel) {
  if (!payload || typeof payload !== "object" || !Array.isArray(payload.choices)) throw new Error("invalid upstream response");
  const clean = {
    id: typeof payload.id === "string" ? payload.id : `chatcmpl-${crypto.randomUUID()}`,
    object: "chat.completion",
    created: Number.isSafeInteger(payload.created) ? payload.created : Math.floor(Date.now() / 1000),
    model: publicModel,
    choices: payload.choices,
  };
  if (payload.usage && typeof payload.usage === "object") clean.usage = payload.usage;
  return clean;
}

function normalizeForUpstream(body, upstream) {
  return { ...body, model: upstream.model || body.model };
}

async function callUpstreams(env, body, deadlineAt) {
  const upstreams = configuredUpstreams(env).slice(0, 2);
  if (upstreams.length === 0) return errorResponse("gateway_unavailable", "gateway is not configured", 503);
  for (let index = 0; index < upstreams.length; index += 1) {
    const target = upstreams[index];
    const permit = await circuitPermit(env, target.id);
    if (!permit.response.ok || !permit.data.allowed) continue;
    const remaining = deadlineAt - Date.now();
    if (remaining <= 0) break;
    let response;
    let retryable = true;
    try {
      response = await fetchWithDeadline(`${target.baseUrl}/chat/completions`, {
        method: "POST",
        headers: { authorization: `Bearer ${target.apiKey}`, "content-type": "application/json" },
        body: JSON.stringify(normalizeForUpstream(body, target)),
      }, Math.min(parsePositiveInt(env.UPSTREAM_TIMEOUT_MS, UPSTREAM_TIMEOUT_MS, UPSTREAM_TIMEOUT_MS), remaining));
      retryable = RETRYABLE_STATUS.has(response.status);
      if (response.ok) {
        const raw = await readLimitedResponse(response);
        const payload = JSON.parse(raw);
        await circuitResult(env, target.id, true, false);
        return jsonResponse(cleanSuccessPayload(payload, body.model));
      }
      await circuitResult(env, target.id, false, retryable);
      if (!retryable) return errorResponse("upstream_rejected", "upstream rejected the request", 502);
    } catch {
      await circuitResult(env, target.id, false, true);
      retryable = true;
    }
    if (!retryable || index === 1) break;
  }
  return Date.now() >= deadlineAt
    ? errorResponse("gateway_timeout", "upstream request timed out", 504)
    : errorResponse("upstream_unavailable", "upstream service is temporarily unavailable", 502);
}

export class SubjectLimiter {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const windowMs = 60 * 60 * 1000;
    const leaseMs = parsePositiveInt(this.env.LEASE_TIMEOUT_MS, GLOBAL_DEADLINE_MS + 5_000, 120_000);
    if (request.method === "POST" && url.pathname === "/release") {
      const body = await request.json().catch(() => ({}));
      await this.state.storage.transaction(async (transaction) => {
        const stored = (await transaction.get("state")) || { startedAt: Date.now(), count: 0, leases: {} };
        if (typeof body.lease_id === "string") delete stored.leases[body.lease_id];
        await transaction.put("state", stored);
      });
      return jsonResponse({ released: true });
    }
    if (request.method !== "POST" || url.pathname !== "/acquire") return errorResponse("not_found", "not found", 404);
    const result = await this.state.storage.transaction(async (transaction) => {
      const now = Date.now();
      const stored = (await transaction.get("state")) || { startedAt: now, count: 0, leases: {} };
      if (now - stored.startedAt >= windowMs) {
        stored.startedAt = now;
        stored.count = 0;
      }
      stored.leases = Object.fromEntries(Object.entries(stored.leases || {}).filter(([, expiresAt]) => expiresAt > now));
      if (stored.count >= 30) {
        return { status: 429, body: { allowed: false, reason: "rate", retry_after: Math.max(1, Math.ceil((stored.startedAt + windowMs - now) / 1000)) } };
      }
      if (Object.keys(stored.leases).length >= 2) return { status: 409, body: { allowed: false, reason: "concurrency" } };
      const leaseId = crypto.randomUUID();
      stored.count += 1;
      stored.leases[leaseId] = now + leaseMs;
      await transaction.put("state", stored);
      return { status: 200, body: { allowed: true, lease_id: leaseId } };
    });
    return jsonResponse(result.body, result.status);
  }
}

export class UpstreamCircuit {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/permit") {
      const allowed = await this.state.storage.transaction(async (transaction) => {
        const now = Date.now();
        const stored = (await transaction.get("state")) || { failures: 0, openUntil: 0, probeActive: false };
        if (stored.openUntil > now || (stored.openUntil > 0 && stored.probeActive)) return false;
        if (stored.openUntil > 0) {
          stored.probeActive = true;
          await transaction.put("state", stored);
        }
        return true;
      });
      return jsonResponse({ allowed });
    }
    if (request.method === "POST" && url.pathname === "/result") {
      const body = await request.json().catch(() => ({}));
      await this.state.storage.transaction(async (transaction) => {
        const stored = (await transaction.get("state")) || { failures: 0, openUntil: 0, probeActive: false };
        if (body.success) {
          await transaction.put("state", { failures: 0, openUntil: 0, probeActive: false });
        } else if (body.retryable) {
          const failures = stored.failures + 1;
          await transaction.put("state", { failures, openUntil: failures >= 5 ? Date.now() + 30_000 : 0, probeActive: false });
        } else {
          stored.probeActive = false;
          await transaction.put("state", stored);
        }
      });
      return jsonResponse({ recorded: true });
    }
    return errorResponse("not_found", "not found", 404);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/") {
      return jsonResponse({ ok: true, service: "TCP-optimization AI gateway", endpoint: "/v1/chat/completions" });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/chat/completions") return errorResponse("not_found", "not found", 404);
    if (!env.SUBJECT_LIMITER || !env.UPSTREAM_CIRCUIT) return errorResponse("gateway_unavailable", "gateway state is not configured", 503);

    const identity = await authenticateAndIdentify(request, env);
    if (identity.error) return identity.error;
    const contentType = (request.headers.get("content-type") || "").split(";", 1)[0].trim().toLowerCase();
    if (!(contentType === "application/json" || (contentType.startsWith("application/") && contentType.endsWith("+json")))) {
      return errorResponse("unsupported_media_type", "application/json is required", 415);
    }
    let raw;
    try {
      raw = await readLimitedBody(request);
    } catch (error) {
      const status = error && error.status ? error.status : 400;
      return errorResponse(status === 413 ? "body_too_large" : "invalid_body", error.message || "invalid request body", status);
    }
    let incoming;
    try {
      incoming = JSON.parse(raw);
    } catch {
      return errorResponse("invalid_json", "invalid JSON body", 400);
    }
    const sanitized = sanitizeChatBody(incoming);
    if (sanitized.error) return errorResponse("invalid_request", sanitized.error, 400);

    const lease = await acquireLease(env, identity.subject);
    if (!lease.response.ok || !lease.data.allowed) {
      const isRate = lease.response.status === 429 || lease.data.reason === "rate";
      return errorResponse(isRate ? "rate_limit_exceeded" : "concurrency_limit_exceeded",
        isRate ? "rate limit exceeded" : "too many concurrent requests", isRate ? 429 : 429,
        lease.data.retry_after ? { "retry-after": String(lease.data.retry_after) } : {});
    }
    try {
      return await callUpstreams(env, sanitized.body, Date.now() + GLOBAL_DEADLINE_MS);
    } finally {
      await releaseLease(env, identity.subject, lease.data.lease_id);
    }
  },
};

export const __test = { readLimitedBody, sanitizeChatBody, configuredUpstreams, cleanSuccessPayload };
