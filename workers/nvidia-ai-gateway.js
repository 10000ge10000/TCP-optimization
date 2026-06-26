const UPSTREAM_BASE_URL = "https://integrate.api.nvidia.com/v1";
const ALLOWED_MODELS = new Set([
  "minimaxai/minimax-m3",
  "moonshotai/kimi-k2.6",
  "minimaxai/minimax-m2.7",
  "z-ai/glm-5.1",
]);

const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000;
const RATE_LIMIT_MAX = 30;
const MAX_BODY_BYTES = 64 * 1024;
const MAX_TOKENS_LIMIT = 768;

const buckets = new Map();

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function getClientIp(request) {
  return request.headers.get("cf-connecting-ip") || "unknown";
}

function checkRateLimit(ip) {
  const now = Date.now();
  const current = buckets.get(ip);
  if (!current || now - current.startedAt > RATE_LIMIT_WINDOW_MS) {
    buckets.set(ip, { startedAt: now, count: 1 });
    return true;
  }
  current.count += 1;
  return current.count <= RATE_LIMIT_MAX;
}

function sanitizeChatBody(body) {
  if (!body || typeof body !== "object") {
    return { error: "request body must be a JSON object" };
  }
  if (!ALLOWED_MODELS.has(body.model)) {
    return { error: "model is not allowed" };
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return { error: "messages must be a non-empty array" };
  }

  const maxTokens = Number(body.max_tokens || 256);
  return {
    body: {
      model: body.model,
      messages: body.messages.slice(0, 16),
      temperature: 0,
      max_tokens: Math.max(1, Math.min(MAX_TOKENS_LIMIT, Number.isFinite(maxTokens) ? maxTokens : 256)),
    },
  };
}

function upstreamKeys(env) {
  return [env.NVIDIA_API_KEY, env.NVIDIA_API_KEY_2].filter(Boolean);
}

function keyOrder(keys) {
  if (keys.length <= 1) return keys;
  return Math.random() < 0.5 ? keys : [keys[1], keys[0]];
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      return jsonResponse({
        ok: true,
        service: "TCP-optimization NVIDIA gateway",
        endpoints: ["/v1/chat/completions"],
        models: Array.from(ALLOWED_MODELS),
      });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return jsonResponse({ error: "not found" }, 404);
    }

    const keys = upstreamKeys(env);
    if (keys.length === 0) {
      return jsonResponse({ error: "gateway is not configured" }, 500);
    }

    const ip = getClientIp(request);
    if (!checkRateLimit(ip)) {
      return jsonResponse({ error: "rate limit exceeded" }, 429);
    }

    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > MAX_BODY_BYTES) {
      return jsonResponse({ error: "request body too large" }, 413);
    }

    let incoming;
    try {
      incoming = await request.json();
    } catch {
      return jsonResponse({ error: "invalid JSON body" }, 400);
    }

    const sanitized = sanitizeChatBody(incoming);
    if (sanitized.error) {
      return jsonResponse({ error: sanitized.error }, 400);
    }

    let upstream;
    const orderedKeys = keyOrder(keys);
    for (let i = 0; i < orderedKeys.length; i += 1) {
      upstream = await fetch(`${UPSTREAM_BASE_URL}/chat/completions`, {
        method: "POST",
        headers: {
          "authorization": `Bearer ${orderedKeys[i]}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(sanitized.body),
      });
      if (![429, 500, 502, 503, 504].includes(upstream.status) || i === orderedKeys.length - 1) {
        break;
      }
    }

    const responseHeaders = new Headers(upstream.headers);
    responseHeaders.delete("set-cookie");
    responseHeaders.set("cache-control", "no-store");

    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders,
    });
  },
};
