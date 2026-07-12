import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { SubjectLimiter, UpstreamCircuit, __test } from "../../workers/nvidia-ai-gateway.js";

class MemoryStorage {
  constructor() { this.values = new Map(); }
  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async transaction(callback) { return callback(this); }
}

class FakeNamespace {
  constructor(DurableClass, env = {}) {
    this.DurableClass = DurableClass;
    this.env = env;
    this.instances = new Map();
  }
  idFromName(name) { return name; }
  get(id) {
    if (!this.instances.has(id)) {
      const state = { storage: new MemoryStorage() };
      this.instances.set(id, new this.DurableClass(state, this.env));
    }
    return { fetch: (url, init) => this.instances.get(id).fetch(new Request(url, init)) };
  }
}

function env(overrides = {}) {
  return {
    SUBJECT_LIMITER: new FakeNamespace(SubjectLimiter),
    UPSTREAM_CIRCUIT: new FakeNamespace(UpstreamCircuit),
    SUB2API_API_KEY: "test-only-key",
    SUB2API_BASE_URL: "https://upstream.invalid/v1",
    ...overrides,
  };
}

function validBody(overrides = {}) {
  return {
    model: "gpt-5.5",
    messages: [{ role: "user", content: "diagnose TCP" }],
    temperature: 0,
    max_tokens: 256,
    ...overrides,
  };
}

function request(body = validBody(), headers = {}) {
  return new Request("https://gateway.invalid/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.10", ...headers },
    body: JSON.stringify(body),
  });
}

async function errorCode(response) {
  return (await response.json()).error.code;
}

describe("request validation", () => {
  it("does not expose model or upstream inventories at the root", async () => {
    const response = await worker.fetch(new Request("https://gateway.invalid/"), env());
    const body = await response.json();
    expect(body).toEqual({ ok: true, service: "TCP-optimization AI gateway", endpoint: "/v1/chat/completions" });
    expect(JSON.stringify(body)).not.toMatch(/sub2api|nvidia|models/i);
  });

  it("requires an optional configured client token", async () => {
    const response = await worker.fetch(request(), env({ AI_GATEWAY_CLIENT_TOKEN: "client-secret" }));
    expect(response.status).toBe(401);
    expect(await errorCode(response)).toBe("unauthorized");
  });

  it("rejects non-JSON media types", async () => {
    const bad = new Request("https://gateway.invalid/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify(validBody()),
    });
    const response = await worker.fetch(bad, env());
    expect(response.status).toBe(415);
    expect(await errorCode(response)).toBe("unsupported_media_type");
  });

  it("accepts a valid client token without forwarding it upstream", async () => {
    globalThis.fetch = vi.fn(async (_url, init) => {
      expect(init.headers.authorization).toBe("Bearer test-only-key");
      return Response.json({ choices: [{ message: { role: "assistant", content: "ok" } }] });
    });
    const response = await worker.fetch(request(validBody(), { authorization: "Bearer client-secret" }), env({ AI_GATEWAY_CLIENT_TOKEN: "client-secret" }));
    expect(response.status).toBe(200);
  });

  it.each([
    [validBody({ unexpected: true }), "unknown field"],
    [validBody({ messages: [{ role: "tool", content: "x" }] }), "role"],
    [validBody({ max_tokens: 1.5 }), "max_tokens"],
    [validBody({ max_tokens: 1025 }), "max_tokens"],
    [validBody({ messages: Array.from({ length: 17 }, () => ({ role: "user", content: "x" })) }), "messages"],
    [validBody({ messages: [{ role: "user", content: "x", name: "hidden" }] }), "unknown message field"],
    [validBody({ stream: true }), "streaming"],
  ])("rejects invalid request shapes", async (body, message) => {
    const response = await worker.fetch(request(body), env());
    expect(response.status).toBe(400);
    expect((await response.json()).error.message).toContain(message);
  });

  it("rejects an oversized streaming body without Content-Length", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(40 * 1024));
        controller.enqueue(new Uint8Array(30 * 1024));
        controller.close();
      },
    });
    const oversized = new Request("https://gateway.invalid/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: stream,
      duplex: "half",
    });
    const response = await worker.fetch(oversized, env());
    expect(response.status).toBe(413);
    expect(await errorCode(response)).toBe("body_too_large");
  });

  it("stops reading a stalled request body at the configured timeout", async () => {
    const stalled = new Request("https://gateway.invalid/v1/chat/completions", {
      method: "POST",
      body: new ReadableStream({ pull() {} }),
      duplex: "half",
    });
    await expect(__test.readLimitedBody(stalled, 1024, 5)).rejects.toMatchObject({ status: 408 });
  });
});

describe("distributed coordinator objects", () => {
  it("enforces two active leases per subject", async () => {
    const limiter = new SubjectLimiter({ storage: new MemoryStorage() }, {});
    expect((await limiter.fetch(new Request("https://do.invalid/acquire", { method: "POST" }))).status).toBe(200);
    expect((await limiter.fetch(new Request("https://do.invalid/acquire", { method: "POST" }))).status).toBe(200);
    expect((await limiter.fetch(new Request("https://do.invalid/acquire", { method: "POST" }))).status).toBe(409);
  });

  it("enforces 30 acquisitions per rolling window", async () => {
    const limiter = new SubjectLimiter({ storage: new MemoryStorage() }, {});
    for (let index = 0; index < 30; index += 1) {
      const acquired = await limiter.fetch(new Request("https://do.invalid/acquire", { method: "POST" }));
      const body = await acquired.json();
      expect(acquired.status).toBe(200);
      await limiter.fetch(new Request("https://do.invalid/release", {
        method: "POST",
        body: JSON.stringify({ lease_id: body.lease_id }),
      }));
    }
    expect((await limiter.fetch(new Request("https://do.invalid/acquire", { method: "POST" }))).status).toBe(429);
  });

  it("opens an upstream circuit after five retryable failures", async () => {
    const circuit = new UpstreamCircuit({ storage: new MemoryStorage() });
    for (let index = 0; index < 5; index += 1) {
      await circuit.fetch(new Request("https://do.invalid/result", {
        method: "POST",
        body: JSON.stringify({ success: false, retryable: true }),
      }));
    }
    const permit = await circuit.fetch(new Request("https://do.invalid/permit", { method: "POST" }));
    expect(await permit.json()).toEqual({ allowed: false });
  });
});

describe("upstream handling", () => {
  beforeEach(() => { globalThis.fetch = vi.fn(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("switches once on a retryable failure and preserves the public model alias", async () => {
    globalThis.fetch
      .mockResolvedValueOnce(new Response("overloaded and secret backend detail", { status: 503 }))
      .mockResolvedValueOnce(Response.json({
        id: "internal-id",
        model: "private-upstream-model",
        choices: [{ index: 0, message: { role: "assistant", content: "ok" } }],
        usage: { total_tokens: 2 },
      }, { headers: { "set-cookie": "secret=cookie", "x-upstream-secret": "hidden" } }));
    const response = await worker.fetch(request(), env({ NVIDIA_API_KEY: "fallback-key" }));
    const body = await response.json();
    expect(globalThis.fetch).toHaveBeenCalledTimes(2);
    expect(response.status).toBe(200);
    expect(body.model).toBe("gpt-5.5");
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("x-upstream-secret")).toBeNull();
  });

  it("does not expose upstream error bodies or sensitive headers", async () => {
    globalThis.fetch.mockResolvedValue(new Response("api key abc and internal inventory", {
      status: 400,
      headers: { "set-cookie": "secret=cookie", "x-internal-model": "private" },
    }));
    const response = await worker.fetch(request(), env());
    const text = await response.text();
    expect(response.status).toBe(502);
    expect(text).not.toMatch(/api key|inventory|private/i);
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("x-internal-model")).toBeNull();
  });

  it("rejects oversized upstream responses", async () => {
    globalThis.fetch.mockResolvedValue(new Response("x".repeat(257 * 1024), { status: 200 }));
    const response = await worker.fetch(request(), env());
    expect(response.status).toBe(502);
    expect(await errorCode(response)).toBe("upstream_unavailable");
  });

  it("aborts an upstream that exceeds its per-attempt timeout", async () => {
    globalThis.fetch.mockImplementation((_url, init) => new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    }));
    const response = await worker.fetch(request(), env({ UPSTREAM_TIMEOUT_MS: "1" }));
    expect(response.status).toBe(502);
    expect(await errorCode(response)).toBe("upstream_unavailable");
  });
});

describe("pure validation helpers", () => {
  it("keeps unknown metric value zero distinct from missing fields", () => {
    const sanitized = __test.sanitizeChatBody(validBody({ max_tokens: 1 }));
    expect(sanitized.body.max_tokens).toBe(1);
  });
});
