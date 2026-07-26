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

离线评估 AI 决策：

```sh
python tests/validation/ai_evaluate.py \
  tests/fixtures/ai/synthetic-scenarios.jsonl \
  tests/fixtures/ai/synthetic-reference-decisions.jsonl \
  -o ai-evaluation.json
```

场景记录标注 development/holdout、目标、方向、角色、平台、协议、故障类型、期望动作、诊断类别、候选 ID、安全关键性、本轮可引用的 `evidence_catalog` 和可回放的 synthetic `input_snapshot`。模型输出使用外层 `scenario_id` 与扁平 `decision` 对象；`evidence_ids` 和 `reason_codes` 是非重复的逗号分隔机器码，`evidence_ids` 不得为空，空的 candidate/measurement 使用空字符串。评测器以 `src/ai/protocol.sh` 为唯一契约，严格校验 `schema_version/action/diagnosis_class/confidence_milli/candidate_id/measurement_id/evidence_ids/reason_codes/expected_metric/expected_direction/stop_reason`，并计算：

- schema 通过率；
- 安全关键场景的正确动作召回率；
- 动作、诊断与候选准确率；
- evidence 引用有效率和虚构引用数；
- 同一 `repeat_group` 多次决策的一致率。

`tests/fixtures/ai` 提供 48 个 development 和 12 个 holdout，共 60 个标记为 `synthetic` 的离线场景。它们覆盖三目标、双方向、VPS/OpenWrt、只读平台、UDP/QUIC、异常指标、上一轮失败和提示注入，用于验证 L2 决策协议与标注准确性；不等于真实模型调用结果，也不能证明真实网络性能改善。只有外部模型产生的决策通过同一评分器后，才能报告该模型的离线指标。

对 OpenAI-compatible 公共网关执行脱敏 holdout 探测（会产生真实网络请求和配额消耗，不在普通 CI 运行）：

```sh
python3 tests/validation/ai_live_probe.py \
  tests/fixtures/ai/synthetic-scenarios.jsonl \
  --split holdout | \
python3 tests/validation/ai_evaluate.py \
  tests/fixtures/ai/synthetic-scenarios.jsonl \
  - --split holdout
```

探测工具不会输出模型推理或原始响应，只保存严格合法决策或短错误码。私有网关 token 只从环境变量读取。

运行测试：

```sh
python -m unittest discover -s tests/validation -p 'test_*.py'
```
