# v0.2.0 双端真实验证报告

验证日期：2026-07-12 至 2026-07-13（Asia/Shanghai）
结论范围：单个 OpenWrt 家庭出口与单个 Debian VPS 之间的真实 TCP 链路，不代表所有运营商、地区或时段。

## 环境与拓扑

```text
Windows 11 / OpenWrt x86_64
          │ IPv4 / IPv6
          ▼
Debian 13 VPS（测试 Agent 39218，iperf3 5218）
```

真实地址、用户名、token、密钥路径和主机标识均未写入仓库。VPS 原有 5202 iperf3 服务未被停止。

| 端点 | 系统与内核 | iperf3 | 主要 TCP 状态 |
|---|---|---|---|
| VPS | Debian 13，Linux 6.12.94 | 3.18 | BBR + fq，内存约 442 MiB |
| OpenWrt | x86_64，Linux 6.6.127 | 3.17.1 | BBR + fq_codel，内存约 7.6 GiB |
| Windows | Windows 11，PowerShell 5.1 | 固定 3.18 | 只测速和建议，不写系统 TCP 栈 |

OpenWrt 缺少 `tc`，因此 qdisc drop/backlog 实测状态应为 `unsupported`，不能伪装成数值 0。链路 RTT 约 59 ms。

## 方法

- 正式共享基线使用 P1、20 秒、相同端点和端口，IPv4/IPv6 上传下载各 5 次，共 20 次。
- 吞吐 CV 均低于 10%，未扩展到 10 次；首秒和重传异常值仍保留在统计中。
- Git `HEAD` 用于旧逻辑对照；候选版使用 5 样本中位数、离散度和写入后复测。
- 统计工具输出均值、中位数、最小/最大值、样本标准差、CV、Tukey 异常值、成功率和失败原因。配对比较工具使用固定 seed、10,000 次 bootstrap。
- 原始未脱敏日志只保存在受限临时目录；仓库仅保存脱敏代表性 fixtures。

代表性命令（地址和 token 使用占位符）：

```sh
iperf3 -4 -c <VPS_IPV4> -p 5218 -t 20 -P 1 -J
iperf3 -6 -c <VPS_IPV6> -p 5218 -t 20 -P 1 -R -J

TCP_TUNE_SAMPLE_COUNT=5 sh tcp-tune.sh --yes --no-color auto \
  --host <VPS_IPV6> --port 5218 --direction upload \
  --objective retrans --rounds 2 --rtt-ms 59

sh tcp-tune.sh --no-color advanced-diagnose \
  --host <VPS_IPV6> --port 5218 --seconds 5 \
  --machine-role endpoint --critical-direction both --protocol-class tcp
```

```powershell
.\tcp-tune.ps1 join -Peer http://<VPS>:39218 -Token $token \
  -IperfPort 5218 -Direction upload -Objective retrans \
  -Rounds 1 -NonInteractive -NoColor -Yes
```

## 修改前共享基线

吞吐单位为 Mbps，重传和首秒仍保留完整 JSON 供解析测试。

| IP 家族 | 方向 | 成功率 | 吞吐均值 | 吞吐中位 | 最低–最高 | 吞吐 CV | 重传中位 | 首秒中位 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| IPv4 | 上传 | 5/5 | 63.03 | 62.63 | 62.47–64.76 | 1.53% | 13,832 | 143.50 Mbps |
| IPv4 | 下载 | 5/5 | 1193.20 | 1207.74 | 1151.21–1213.01 | 2.24% | 136,602 | 859.97 Mbps |
| IPv6 | 上传 | 5/5 | 62.17 | 61.72 | 61.47–64.29 | 1.91% | 13,913 | 142.50 Mbps |
| IPv6 | 下载 | 5/5 | 1199.71 | 1191.85 | 1183.59–1225.56 | 1.46% | 135,048 | 836.66 Mbps |

吞吐稳定不代表重传或首秒稳定。例如 IPv6 上传重传 CV 为 16.8%，IPv6 下载重传 CV 为 20.6%，证明单次结果不足以判定调参效果。

## HEAD 与候选逻辑对照

| 模式 | 版本 | 写入前 | 写入后 | 实际判定 |
|---|---|---|---|---|
| 重传优先 / IPv6 上传 | HEAD | 61.8 Mbps / 10,734 | 60.3 Mbps / 5,981 | 单次样本显示重传下降 44%，旧版保留参数 |
| 重传优先 / IPv6 上传 | 候选 | 5 样本组 | 补测后仍超过 10% 离散 | 写入前退出码 6，无参数写入 |
| 吞吐优先 / IPv6 下载 | HEAD | 1.17 Gbps / 186,121 | 1.18 Gbps / 173,649 | 未达到吞吐阈值，回滚 |
| 吞吐优先 / IPv6 下载 | 候选 | 1.19 Gbps / 147,801 | 1.15 Gbps / 184,408 | 吞吐下降且重传增加 25%，回滚 |
| 快速起速 / IPv6 上传 | HEAD | 首段 244.1 Mbps | 首段 170.7 Mbps | 使用 `-O 3` 后首段，退化后回滚 |
| 快速起速 / IPv6 上传 | 候选 | 真实首秒 152.9 Mbps | 真实首秒 144.5 Mbps | 首秒下降约 5.5%，回滚 |

候选版没有在本链路上证明可稳定提高速度；已经证明的是它能识别波动和目标退化并拒绝错误保留。HEAD 的“重传下降 44%”不能作为优化结论，因为候选版的重复样本确认该方向波动超过阈值。

## 高级诊断和方向验证

候选版实测：

| 测试 | 上传 | 下载 |
|---|---|---|
| P1 | 74.6 Mbps / 13,094 重传 / 首秒 245.1 Mbps | 1.20 Gbps / 70,887 重传 / 首秒 811.8 Mbps |
| P4 | 74.9 Mbps / 15,063 重传 / 首秒 243.0 Mbps | 1.14 Gbps / 419 重传 / 首秒 654.7 Mbps |

P4 只用于容量诊断，没有参与参数保留。真实 JSON 确认：上传和 `-R` 下载吞吐均取 `end.sum_received`，重传取实际发送端的 `end.sum_sent.retransmits`，首秒取第一个真实 interval。OpenWrt 3.17.1、VPS 3.18、临时构建的 3.16 均产生了真实样本；3.16 到 OpenWrt 的入站连接被网络策略拒绝，该失败样本同样保留。

## Agent、安全和异常结果

| 场景 | 实际结果 |
|---|---|
| 无 token / 错 token | 403 / 403 |
| header token / query token | 200 / 403 |
| `/optimize`、`/apply-profile`、`/apply-buffers` | 全部 403 |
| 非法 direction、负数指标、未知字段、非法 JSON | 全部 400 |
| 32 KiB 以上实际 body | 413 |
| 未授权私网 `/test` | 403 |
| 固定 `restore-defaults` | 200，未接受任意参数 |
| token 出现在进程参数或服务日志 | 否 / 否 |
| 同端口重复启动 | 退出码 4，原会话继续运行 |
| 15 秒 TTL | Agent、iperf3、token 全部主动清理 |
| 用户 5202 iperf3 / PID 复用 | 身份不匹配，均未停止 |
| 不存在 sysctl | 跳过并记录 `unsupported-kernel` |
| 有效参数后接不可写参数 | 事务失败，运行值和文件完整恢复 |
| 客户端 SIGINT/TERM | 修复前短暂遗留 iperf3；修复后参数恢复且子进程立即为 0 |

## Windows 实测

Windows 固定资产下载通过 SHA256 和版本校验。修复 IPv4 bind 被错误用于 IPv6 目标后，IPv4/IPv6 双向各 5 次均成功。

| 家族 | 方向 | 成功率 | 吞吐中位 | 吞吐 CV | 首秒中位 | 重传 |
|---|---|---:|---:|---:|---:|---|
| IPv4 | 上传 | 5/5 | 61.95 Mbps | 2.76% | 248.42 Mbps | iperf Windows 客户端未提供，保持 `null` |
| IPv4 | 下载 | 5/5 | 1.160 Gbps | 2.23% | 749.42 Mbps | 156,100 |
| IPv6 | 上传 | 5/5 | 61.92 Mbps | 2.71% | 234.87 Mbps | 未提供，保持 `null` |
| IPv6 | 下载 | 5/5 | 1.158 Gbps | 0.13% | 741.37 Mbps | 138,632 |

Windows 完整配对首次因 Agent 拒绝 `null` 指标而失败；协议修复为允许 `null`、继续拒绝字符串和负数后，同一命令退出码为 0，页面显示“未检测”，没有误判为 0 或达标。Windows 未修改本机 TCP 栈，因此无需回滚。

## 实测推动的代码修正

1. 提前回滚后的完成轮数改为实际轮数。
2. `unsupported`、`failed`、`unknown` 和真实 0 分离。
3. Python/jsonfilter/awk 解析统一接收端吞吐和发送端重传；不安全 fallback 显式失败。
4. Shell 和 Windows 都只在地址族匹配时使用本地 bind。
5. Windows 缺失重传不再显示绿色或参与目标比较。
6. Agent 严格校验枚举、范围和类型，同时允许 `null` 表示未知。
7. 仪表盘不再把非法方向显示为下载或把缺失指标显示为 0。
8. 高级诊断的 POSIX 全局变量污染已修复，不再显示“P1 上传 下载”。
9. iperf3 客户端纳入 session/进程身份 manifest，中断时只清理本项目子进程。

## AI 验证

公共网关真实模型选择成功并返回 `gpt-5.5`。AI 自动优化在 5 样本上传阶段因波动过大以退出码 6 停止，未执行写入；随后真实摘要诊断调用出现一次结构化响应和一次上游超时。故只能证明客户端失败关闭和结构化边界有效，不能证明 AI 调参能提升当前链路。

候选 Durable Object Worker 未部署，本报告不声称线上 Worker 已验证。

## 未达到预期、撤销和未验证项

- 本链路没有任何候选参数达到项目保留阈值；所有写入均回滚，不能宣称速度提升。
- HEAD 重传模式的单次“改善”被重复样本判定为不可靠，不继承该结论。
- 候选下载吞吐和上传首秒参数均产生副作用，已撤销。
- 快速起速下载方向未单独完成 5 样本写入前后组；已有下载基线和方向解析，但该目标组合标记“未完成真实验证”。
- macOS：未完成真实验证，缺少设备。
- PowerShell 7：未完成本机真实验证，仅由 CI 矩阵覆盖。
- 当前 Durable Object Worker 部署：未完成真实验证，本次未部署。

## 结论

v0.2.0 在本次环境中证明了方向解析、重复样本、目标判定、失败关闭、事务回滚、Agent 只读边界和进程清理的实际作用。它没有证明能够在该链路上稳定提高吞吐或降低重传；准确结论是：**安全判断和回滚闭环有效，链路性能提升未被证明。**
