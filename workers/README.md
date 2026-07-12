# AI Gateway Worker

该 Worker 只提供 OpenAI 兼容的 `POST /v1/chat/completions`，用于把 TCP 调优摘要转发到受控上游。根端点只返回健康状态，不公开真实模型或上游清单。

## 安全边界

- 请求体实际读取上限为 64 KiB，读取超时 5 秒；不依赖 `Content-Length`。
- `messages` 限 1–16 条，角色只允许 `system`、`user`、`assistant`；单条 12,000 字符，总计 32,000 字符。
- `max_tokens` 必须是 1–1024 的整数；不支持流式响应。
- `SubjectLimiter` 按客户端 token 哈希或来源 IP 哈希分片，限制每主体每小时 30 次、最多 2 个并发租约。
- `UpstreamCircuit` 按上游分片；连续 5 次可重试失败后熔断 30 秒。
- 单上游最多等待 30 秒，整次上游调用最多 45 秒，最多尝试两个已配置上游。
- 上游错误正文和响应头不会透传；成功响应最大 256 KiB，并将模型名还原为客户端使用的公开别名。

> Durable Object 配额是 Worker 的权威限制。不要删除 `wrangler.toml` 中的 binding 和 migration。

## 环境变量与 Secret

至少配置一个上游 Secret：

- `SUB2API_API_KEY`（兼容 `TCP_TUNE_SUB2API_API_KEY`）
- `NVIDIA_API_KEY`
- `NVIDIA_API_KEY_2`

可选配置：

- `AI_GATEWAY_CLIENT_TOKEN`：启用客户端 Bearer 鉴权；未配置时保持公共兼容模式。
- `SUB2API_BASE_URL`、`SUB2API_MODEL`
- `NVIDIA_BASE_URL`
- `UPSTREAM_TIMEOUT_MS`：可下调上游超时，不能超过 30 秒。

所有密钥都必须通过 `wrangler secret put` 或 Cloudflare 控制台保存，禁止写入仓库或 `wrangler.toml`。

客户端示例：

```sh
export TCP_TUNE_AI_GATEWAY_URL="https://你的-worker.workers.dev/v1"
export TCP_TUNE_AI_GATEWAY_TOKEN="与 AI_GATEWAY_CLIENT_TOKEN 相同的值"
```

## 本地验证

```sh
npm ci
npm test
npm run check:worker
npm run build:worker
```

`build:worker` 只执行 Wrangler dry-run，不会部署。测试使用模拟上游，不需要真实 API Key。
