# TCP-optimization AI Gateway

Cloudflare Workers 网关，用于把项目脚本的 OpenAI-compatible 请求转发到 NVIDIA。

安全边界：

- `NVIDIA_API_KEY` 只作为 Worker Secret 保存。
- 只开放 `/v1/chat/completions`。
- 只允许项目默认模型白名单。
- 限制 `max_tokens`、请求体大小和简单 IP 频率。
- 不记录请求正文，不返回上游 Key。

脚本使用：

```sh
export TCP_TUNE_AI_GATEWAY_URL="https://你的-worker.workers.dev/v1"
sh tcp-tune.sh ai-benchmark-models
```
