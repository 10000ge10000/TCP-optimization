# TCP-optimization 架构

## 项目定位

TCP-optimization 是面向 VPS 与 OpenWrt、Linux、macOS、Windows 客户端的双端 TCP 测速和调优工具。服务端提供临时 HTTP Agent 与 iperf3，客户端负责测速、诊断和受控的本机优化。

核心不变量：

- 服务端默认只读，不接受远程提交的任意 sysctl 参数。
- OpenWrt 不强制安装 Python，发行时仍只需下载单文件脚本。
- 所有写入先备份、逐项验证、写入后复测；失败或性能退化立即回滚。
- 不修改防火墙、WAN、DNS、DHCP、代理、路由、forwarding 或用户已有长期 iperf3 服务。
- Windows 与 macOS 默认只测速、诊断和建议，不写 Linux TCP 参数。
- AI 只返回结构化数据，执行层只接受白名单字段与受限数值。

## 技术栈与发布形态

- POSIX Shell：Linux/OpenWrt/macOS 主逻辑，源码位于 `src/`。
- PowerShell：Windows 客户端，根目录保留可直接运行的单文件。
- Python 标准库：服务端临时 HTTP Agent；独立源码在构建时嵌入 Shell 发行版。
- Cloudflare Worker：可选 AI 网关。
- iperf3：单线程为默认调参证据，多线程只用于高级容量诊断。
- sysctl：Linux/OpenWrt 受控参数写入。

仓库采用“源码模块化、发布单文件化”：

```text
src/
├── core/       # 配置、退出码、工具、校验、JSON、UI
├── platform/   # 平台检测、能力矩阵和写入白名单
├── tuning/     # 测速、解析、指标、预设、优化、诊断、事务、回滚
├── agent/      # Agent 生命周期与独立 Python 源码
├── ai/         # AI 客户端、响应 schema 与决策适配
└── cli/        # 命令、菜单、仪表盘和入口

scripts/
├── shell-modules.txt
├── build-shell.sh
└── check-generated.sh

tcp-tune.sh     # 自动生成的单文件发行版
tcp-tune.ps1    # Windows 单文件发行版
```

模块依赖只能单向流动：

```text
core -> platform -> tuning / agent / ai -> cli
```

- `core` 不依赖菜单、Agent 或系统写入业务。
- `platform` 只负责平台能力、参数存在性和允许写入的边界。
- `tuning` 接收显式输入并返回结果，不读取菜单输入或绘制界面。
- `cli` 负责参数解析、交互、调度和展示，不实现底层写入。
- `scripts/shell-modules.txt` 固定合并顺序；构建不加入时间戳，连续构建必须字节一致。
- 根脚本标明自动生成，源码修改必须通过生成一致性检查。

## 运行数据流

服务端会话：

```text
server 命令
  -> 平台与依赖检查
  -> 记录服务端首次 TCP/sysctl 快照
  -> 创建受限状态目录和会话锁
  -> 启动本会话 iperf3 与 HTTP Agent
  -> readiness 检查成功后输出客户端命令
  -> 只读仪表盘
  -> stop / signal / TTL 统一清理
```

客户端会话：

```text
client 命令
  -> 平台与依赖检查
  -> 发现 LAN 地址并向 Agent 配对上报
  -> 客户端菜单或非交互命令
  -> 测速 / 状态 / 诊断 / 受控本机优化
  -> 结果上报与优化前后对比
```

确定性优化：

```text
采集基线（默认 3 次）
  -> 解析对应方向的吞吐、重传、首秒
  -> 合并 RTT、内存、qdisc drop/backlog
  -> 取中位数并检查离散度
  -> BDP 初估 + 平台内存护栏 + 目标模式
  -> 创建 sysctl 事务
  -> 写入并验证实际值
  -> 同口径复测
  -> 保留，或退化/不确定时回滚
```

AI 优化：

```text
脱敏指标与链路上下文
  -> AI 网关
  -> 结构化 JSON
  -> schema、枚举、未知字段和数值边界校验
  -> 平台白名单
  -> 与确定性优化相同的事务写入、复测和回滚
```

`protocol_class=udp-quic` 时，AI 与规则引擎只给出 PMTU、qdisc、CPU 等诊断，不默认写 TCP sysctl。

## 平台能力边界

| 能力 | Linux/VPS | OpenWrt | macOS | Windows |
|---|---:|---:|---:|---:|
| HTTP Agent 服务端 | 支持 | 不推荐 | 不支持 | 不支持 |
| 单/双向 iperf3 | 支持 | 支持 | 支持 | 支持 |
| 高级只读诊断 | 支持 | 支持 | 部分支持 | 部分支持 |
| Linux TCP 参数写入 | 完整受控白名单 | 最小白名单 | 不支持 | 不支持 |
| AI 结构化建议 | 支持 | 支持 | 支持 | 支持 |

OpenWrt 最小参数白名单：

```text
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_limit_output_bytes
```

BBR/qdisc 只作为经过能力检测的基础项，仍必须进入同一个备份、验证和回滚事务。已有 `cake`、`fq_codel` 或 `fq` 时优先尊重现状。

## 指标与决策模型

iperf3 JSON 解析必须兼容版本差异，优先使用 Python3、OpenWrt `jsonfilter`，最后使用由 fixtures 覆盖的 POSIX awk fallback。缺失指标为 `unknown`，不能转成 0。

每轮同时考虑：

- 对应方向吞吐中位数和离散度。
- 重传及其相对变化。
- 无 omit 的首个有效 interval 速度。
- RTT 中位数。
- 可用内存和平台上限。
- qdisc drop/backlog delta。

默认判定阈值集中在配置层：

- 重传优先：重传达到目标或下降至少 15%，吞吐下降不超过 5%，首秒下降不超过 10%。
- 吞吐优先：吞吐提升至少 5%，重传不超过 `max(基线×1.2, 基线+10)`，首秒下降不超过 10%。
- 快速起速：首秒提升至少 7.5%，总吞吐下降不超过 10%，重传使用同一容差。
- 三种目标均不得同时出现 RTT 超过 15% 且 5ms 的恶化，并须通过 qdisc 护栏。

默认每个候选测试 3 次。吞吐离散度超过 10% 时追加一组，仍不稳定则结果为“不确定”并回滚。最后一轮不执行无法继续复测的写入。

OpenWrt 单项 buffer 上限：总内存不超过 128/256/512/1024 MiB 时分别为 4/8/16/32 MiB；更高内存为 `min(64MiB, 总内存5%)`。Linux 默认上限为 `min(256MiB, 总内存10%)`。

## sysctl 事务与回滚

所有写入，包括 BBR/qdisc 基础项，执行同一事务：

1. 检查平台能力、参数白名单和参数是否存在。
2. 保存 live 值，以及项目管理文件的原文、存在性、权限和哈希。
3. 在受限临时目录生成配置并校验内容。
4. fsync 后原子替换项目管理文件。
5. 逐参数加载，不能用整体命令掩盖部分失败。
6. 重新读取并验证内核实际值。
7. 任一步失败时恢复原文件和 live 值并再次验证。
8. 性能复测通过后提交；退化或不确定时回滚。

不支持的非必需参数记录为 `unsupported` 并跳过；必需参数或回滚验证失败必须返回非零退出码。回滚失败不得移动、消费备份或报告成功。工具不直接覆盖 `/etc/sysctl.conf`。

状态与备份默认位于：

```text
/var/lib/tcp-tune/
├── backups/
├── initial-defaults/
├── profiles/latest.md
├── rolled-back/
└── sessions/
```

状态、报告、PID、token、锁和快照指针使用安全临时文件与原子替换；状态目录不得保存 API Key、密码、Cookie 或 SSH 私钥。

## HTTP Agent 协议与生命周期

Agent 默认监听 `0.0.0.0:39188`，通过 CSPRNG 生成的会话 token 鉴权。默认只接受 `X-TCP-Tune-Token` 或 Bearer 请求头；query token 仅在显式兼容开关下接受并输出弃用警告。

| 方法 | 路径 | 作用 |
|---|---|---|
| `GET` | `/status` | 受控获取服务端状态 |
| `GET` | `/defaults` | 查询首次默认快照状态 |
| `GET` | `/events` | 获取有界事件和客户端报告 |
| `GET` | `/state` | 获取脱敏 Agent 状态 |
| `POST` | `/report` | 客户端配对与有界状态上报 |
| `POST` | `/test` | 只对配对客户端或 allowlist 触发测试 |
| `POST` | `/restore-defaults` | 回放服务端首次快照，不接受参数 |
| `POST` | `/stop` | 停止当前会话 |

`/optimize`、`/apply-profile` 和 `/apply-buffers` 始终拒绝远程写入。VPS 主动优化只能由本机显式命令触发。

安全边界：

- 明文 HTTP 不提供传输加密；端口应只对测试对端开放或置于可信隧道/VPN。
- 请求体实际读取有上限，不能只信任 `Content-Length`；请求、子进程和总会话均有超时。
- events/reports 是有界队列，字段有类型、枚举和长度限制。
- `/test` 校验 host、端口、时长、leading `-`、地址类别和 DNS 重绑定。
- 同一状态目录和端口使用原子锁；readiness 通过后才发布连接信息。
- PID manifest 保存会话、可执行文件、命令行和启动身份；停止前验证，防止 PID 复用误杀。
- TTL 到期主动停止当前 Agent 与当前会话 iperf3；正常、异常和信号退出共享清理链路。
- 禁止宽泛 `pkill iperf3`。

## AI 网关

Worker 对请求执行可选客户端鉴权、实际 body 大小限制、messages/schema/字符数限制、模型别名与最大输出 token 限制。跨实例限流和并发租约由 Durable Object 提供；上游熔断、总 deadline、有限故障切换和错误清洗避免成本失控及内部信息泄露。

公共网关只能接收 `TCP_TUNE_AI_GATEWAY_TOKEN`；`NVIDIA_API_KEY` 只能发送到明确配置的 NVIDIA 官方直连地址。客户端不会获得上游密钥、内部模型库存或原始错误正文。

## CLI、机器输出与退出码

现有命令、中文别名和菜单编号保持兼容。Shell 支持 `--json`、`--non-interactive`、`--no-color`，PowerShell 对应 `-Json`、`-NonInteractive`、`-NoColor`。

机器输出 envelope：

```json
{
  "schema_version": "1",
  "ok": true,
  "command": "status",
  "data": {},
  "errors": []
}
```

退出码：0 成功；2 参数；3 依赖/平台；4 网络/Agent/TTL；5 鉴权；6 测速；7 写入/验证/回滚；8 AI/上游；130 中断。

## 测试与发布约束

- `scripts/check-generated.sh` 验证连续构建一致且根脚本与模块源码同步。
- Shell 通过 `bash -n`、`dash -n`、BusyBox `ash -n`、ShellCheck `-s sh` 和纯函数测试。
- fake sysctl 与临时状态目录验证事务和 dry-run，CI 不修改真实网络参数。
- PowerShell 通过 Parser 和 Pester；Worker 通过 Node 单元及本地 Worker 测试。
- Agent 集成测试覆盖鉴权、只读端点、body/并发/超时、SSRF、TTL、锁、PID 身份和清理。
- `v*` tag 只触发发布，不由工作流自动创建；Release 先执行完整检查，再生成单文件、压缩包和 `SHA256SUMS`。
- 普通 CI 只读，不使用真实 API Key；真实 AI smoke 仅允许手动、受保护 environment、单并发运行。

## 架构决策记录

- 服务端承担 Agent：避免给资源有限的 OpenWrt 强制安装 Python。
- 临时 HTTP + token：服务于一键短时配对，不等同于安全的公网长期管理接口。
- 服务端默认只读：远程端不能提交任意 sysctl，恢复默认只回放固定快照。
- 单文件发行：模块化提升维护性，同时保持 curl 管道与 OpenWrt 一键运行兼容。
- 事务式写入：配置文件成功写入不代表内核全部生效，必须逐项验证并可恢复。
- 多次测速：用中位数和离散度避免把单次链路波动误判为优化。
- 只停止项目进程：进程身份验证优先于 PID 文件本身，避免影响用户服务。
