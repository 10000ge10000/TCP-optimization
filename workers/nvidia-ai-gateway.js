const DEFAULT_SUB2API_BASE_URL = "https://api.910501.xyz/v1";
const DEFAULT_SUB2API_MODEL = "gpt-5.5";
const DEFAULT_NVIDIA_BASE_URL = "https://integrate.api.nvidia.com/v1";
const ALLOWED_MODELS = new Set([
  "tcp-tune-default",
  "gpt-5.5",
  "minimaxai/minimax-m3",
  "moonshotai/kimi-k2.6",
  "minimaxai/minimax-m2.7",
  "z-ai/glm-5.1",
]);

const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000;
const RATE_LIMIT_MAX = 30;
const MAX_BODY_BYTES = 64 * 1024;
const MAX_TOKENS_LIMIT = 4096;
const UPSTREAM_TIMEOUT_MS = 45 * 1000;

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

function configuredUpstreams(env) {
  const upstreams = [];
  const sub2apiKey = env.SUB2API_API_KEY || env.TCP_TUNE_SUB2API_API_KEY;
  if (sub2apiKey) {
    upstreams.push({
      name: "sub2api",
      baseUrl: (env.SUB2API_BASE_URL || DEFAULT_SUB2API_BASE_URL).replace(/\/+$/, ""),
      apiKey: sub2apiKey,
      model: env.SUB2API_MODEL || DEFAULT_SUB2API_MODEL,
    });
  }
  for (const key of [env.NVIDIA_API_KEY, env.NVIDIA_API_KEY_2].filter(Boolean)) {
    upstreams.push({
      name: "nvidia",
      baseUrl: (env.NVIDIA_BASE_URL || DEFAULT_NVIDIA_BASE_URL).replace(/\/+$/, ""),
      apiKey: key,
      model: null,
    });
  }
  return upstreams;
}

function normalizeForUpstream(body, upstream) {
  return {
    ...body,
    // sub2api owns the real model routing. Public clients can keep using old
    // model names without learning the private upstream model inventory.
    model: upstream.model || body.model,
  };
}

async function fetchWithTimeout(url, init, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort("upstream timeout"), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      return jsonResponse({
        ok: true,
        service: "TCP-optimization AI gateway",
        endpoints: ["/v1/chat/completions"],
        models: Array.from(ALLOWED_MODELS),
        default_model: DEFAULT_SUB2API_MODEL,
        upstream: "sub2api",
      });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return jsonResponse({ error: "not found" }, 404);
    }

    const upstreams = configuredUpstreams(env);
    if (upstreams.length === 0) {
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
    let lastError = "";
    for (let i = 0; i < upstreams.length; i += 1) {
      const target = upstreams[i];
      try {
        upstream = await fetchWithTimeout(`${target.baseUrl}/chat/completions`, {
          method: "POST",
          headers: {
            "authorization": `Bearer ${target.apiKey}`,
            "content-type": "application/json",
          },
          body: JSON.stringify(normalizeForUpstream(sanitized.body, target)),
        }, Number(env.UPSTREAM_TIMEOUT_MS || UPSTREAM_TIMEOUT_MS));
      } catch (error) {
        lastError = `${target.name}: ${error && error.name ? error.name : "fetch failed"}`;
        continue;
      }
      if (![429, 500, 502, 503, 504].includes(upstream.status) || i === upstreams.length - 1) {
        break;
      }
    }

    if (!upstream) {
      return jsonResponse({ error: "all upstreams failed", detail: lastError }, 502);
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
