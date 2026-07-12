# iperf3 验证夹具

此目录保存经过 `tests/validation/sanitize.py` 脱敏的真实 iperf3 JSON。

文件名使用 `<version>-<ipv4|ipv6>-<upload|download>-p<streams>-<ok|failed|truncated>.json`。夹具必须保留方向、interval、`sum_sent`、`sum_received` 和错误结构，但不得包含真实 IP、主机名、用户名、token 或凭据。

原始输出只能放在任务专用的受限临时目录；执行脱敏并人工复核后才能复制到这里。
