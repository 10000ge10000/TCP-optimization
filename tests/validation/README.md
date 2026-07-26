# 双端验证开发工具

统计 JSONL：

```sh
python tests/validation/analyze.py validation.jsonl -o summary.json
```

每条记录必须包含 `variant`、`family`、`direction`、`parallel`、`duration`、`success`、`bps`、`retrans`、`first_bps`、`error` 和 `time`。工具按前五个字段分组，只统计成功样本的数值；失败样本保留在成功率和失败原因中。Tukey 异常值只标记、不删除。

转换真实 iperf3 JSON：

```sh
python tests/validation/iperf_to_jsonl.py \
  candidate__run-01__ipv6__download__p1__d20__20260712T010203Z.json \
  -o validation.jsonl
```

文件名元数据格式为 `<variant>__<run>__<ipv4|ipv6>__<upload|download>__p<N>__d<seconds>[__time].json`，也可用同名命令行参数覆盖。吞吐固定读取 `end.sum_received.bits_per_second`，重传读取 `end.sum_sent.retransmits`，首秒优先读取首个 `interval.sum`，缺失时汇总其 `streams`。任何缺失指标保持 `null`。

按 `run` 比较修改前后：

```sh
python tests/validation/compare.py validation.jsonl -o comparison.json
```

比较器默认计算 `candidate - head`，只配对同一 IP 家族、方向、并发、时长和 `run` 的成功记录。输出 delta 描述统计及固定 seed、10,000 次重采样的均值 bootstrap 95% CI；少于两个有效 delta 时 CI 为 `null`。

脱敏 JSON 或 JSONL：

```sh
python tests/validation/sanitize.py raw.json --format auto -o sanitized.json
```

工具会替换 IP、token、Authorization、Cookie、URL 凭据、用户名和主机标识，并规范化 session 与时间字段。输出进入 fixture 前仍必须人工复核，原始数据不得写入仓库。

运行测试：

```sh
python -m unittest discover -s tests/validation -p 'test_*.py'
```
