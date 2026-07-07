# ARCHITECTURE.md

## 1. 项目概述

`TCP-optimization` 是一个双端 TCP 调优工具，仓库地址：

```text
https://github.com/10000ge10000/TCP-optimization
```

它面向公网 VPS 与 OpenWrt / Linux / macOS / Windows 客户端，通过默认只读服务端、临时 HTTP Agent、iperf3 测试结果和可选 AI 决策完成状态交换、测速、参数推荐、自动调优、首次快照恢复和回滚。

核心体验：

```text
服务端运行 server
  -> 自动安装依赖
  -> 启动 Agent + iperf3
  -> 输出客户端命令
  -> 进入只读监控
客户端运行 client
  -> 自动安装依赖
  -> 上报状态
  -> 进入客户端菜单
客户端通过菜单进行测速和本机优化，服务端默认仅展示状态和结果
恢复默认值时，客户端恢复本机首次快照，并请求服务端恢复启动时快照
显式运行 ai-auto / vps-adapt / local-minimal 时，当前机器可执行受控 sysctl 写入
```

## 2. 技术栈

- Shell：Linux/OpenWrt/macOS 主脚本 `tcp-tune.sh`
- PowerShell：Windows 客户端 `tcp-tune.ps1`
- Python 标准库：服务端临时 HTTP Agent
- 项目 AI 网关：默认转发到 sub2api OpenAI-compatible 接口，可选保留 NVIDIA 备用上游
- iperf3：上传/下载方向测速
- sysctl：Linux/OpenWrt TCP 参数写入
- curl/wget：下载脚本和调用 Agent

## 3. 核心模块职责

`tcp-tune.sh`：

- 系统识别：识别 OpenWrt、Debian/Ubuntu、RHEL 系、macOS。
- 依赖安装：按包管理器自动安装 iperf3、curl、python3。
- 服务端模式：启动 Agent、iperf3，记录首次 TCP/sysctl 快照，输出客户端命令并进入前台只读监控；默认不修改服务端 TCP 参数。
- 客户端模式：探测并上报局域网 IPv4，记录本机首次 TCP/sysctl 快照，进入客户端菜单。
- 智能推荐：按 BDP、RTT、内存和目标生成 TCP 参数。
- 自动优化：提供重传优先、吞吐优先、快速起速三种目标，按 iperf3 Retr、总吞吐和首秒吞吐迭代调整参数；最后一轮不写入未经复测的参数，指标退化时自动撤销最新调整。
- 高级诊断：只读采集 `machine_role`、`critical_direction`、`protocol_class`、PMTU、出口 MTU、qdisc drop/backlog delta、P1/P4 对比，不执行强干预写入。
- AI 自动调参：`ai-auto` 将脱敏测速摘要和链路上下文发送给项目 AI 网关，模型只返回结构化 JSON，脚本按白名单和上下限校验后执行；`udp-quic` 场景只输出建议，不默认写 TCP sysctl。
- 双端适配：`vps-adapt` 主要调整 VPS 发送侧，`local-minimal` 只对 OpenWrt 写入少量必要 TCP 参数。
- 客户端展示：隐藏代理公网地址，展示本机 LAN 地址和语义化测速结果；原始 sysctl 参数降级为详细信息。
- 备份回滚：每次写入前保存 live sysctl 快照；恢复默认值使用首次运行快照，不消费最近一次回滚备份。
- 安全清理：停止本工具创建并记录 pid 的临时 Agent/iperf3。

`tcp-tune.ps1`：

- Windows 状态检测。
- 自动尝试安装 iperf3。
- 探测并上报 Windows 局域网 IPv4，iperf3 使用该地址作为源地址绑定。
- 提供与 Shell 客户端一致的中文菜单和三种目标模式。
- 语义化显示 Mbps/Gbps、重传趋势及快速起速模式的首秒速度。
- 默认不修改 Windows TCP 栈。

## 4. 数据流

服务端：

```text
server
  -> detect_os
  -> install_runtime_deps
  -> start_iperf_server
  -> write_agent_py
  -> start HTTP Agent
  -> print client commands
  -> server_monitor
  -> display client reports and events
```

客户端：

```text
client
  -> detect_os
  -> install_runtime_deps
  -> detect local LAN IPv4
  -> POST /report
  -> client_menu
  -> select objective + direction
  -> iperf3 bind local LAN IPv4
  -> auto/status/events/stop
```

自动优化：

```text
iperf3 JSON
  -> extract Retr / bits_per_second
  -> recommend_values
  -> tune_step
  -> apply_buffers
  -> backup live sysctl
  -> write /etc/sysctl.d/99-tcp-tune.conf
  -> sysctl -p
```

AI 自动调参：

```text
ai-auto
  -> benchmark/select model
  -> iperf3 upload/download baseline
  -> send redacted summary to AI gateway /v1/chat/completions
  -> parse structured JSON decision
  -> validate whitelist and numeric bounds
  -> apply vps-adapt or local-minimal on current host
  -> retest and rollback on regression
```

## 5. Agent 协议

Agent 是临时 HTTP 服务，默认监听 `0.0.0.0:39188`，通过随机 token 校验。

端点：

| 方法 | 路径 | 作用 |
|---|---|---|
| `GET` | `/status` | 获取服务端状态 |
| `GET` | `/defaults` | 查询服务端首次默认快照是否已记录 |
| `GET` | `/events` | 获取事件和客户端上报 |
| `GET` | `/state` | 获取原始 Agent 状态 |
| `POST` | `/report` | 客户端上报状态或测速结果 |
| `POST` | `/test` | 触发服务端 iperf3 测试 |
| `POST` | `/restore-defaults` | 恢复服务端启动时记录的首次 TCP/sysctl 快照 |
| `POST` | `/stop` | 停止服务端会话 |

所有端点都必须通过请求头 `X-TCP-Tune-Token` 或 query token 校验。文档和日志不应泄露 token。普通 `server` 会话中的 `/optimize`、`/apply-profile`、`/apply-buffers` 仍明确返回 `403 server is read-only`；`/restore-defaults` 是固定恢复动作，只能回放服务端启动时记录的快照，不接受客户端提交的任意参数。VPS 主动调参写入必须通过本机显式命令 `ai-auto` 或 `vps-adapt` 触发。

## 6. 配置与状态

环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TCP_TUNE_STATE_DIR` | `/var/lib/tcp-tune` | 运行状态、pid、日志和备份 |
| `TCP_TUNE_SYSCTL_FILE` | `/etc/sysctl.d/99-tcp-tune.conf` | sysctl 写入文件 |
| `TCP_TUNE_AGENT_PORT` | `39188` | HTTP Agent 端口 |
| `TCP_TUNE_IPERF_PORT` | `5201` | iperf3 端口 |
| `TCP_TUNE_SESSION_TTL` | `1800` | 会话有效期 |
| `TCP_TUNE_PUBLIC_URL` | 空 | 手动指定客户端连接 URL |
| `TCP_TUNE_DRY_RUN` | `0` | 预览模式 |
| `TCP_TUNE_AI_GATEWAY_URL` | 项目公共网关 | 普通用户默认无需配置 |
| `TCP_TUNE_AI_GATEWAY_TOKEN` | 空 | 私有网关鉴权令牌，可选 |
| `NVIDIA_API_KEY` | 空 | 直接连接 NVIDIA 时使用；只从环境变量读取 |
| `NVIDIA_BASE_URL` | `https://integrate.api.nvidia.com/v1` | 直接连接 NVIDIA 时的 OpenAI-compatible 接口地址 |
| `NVIDIA_MODEL` | `gpt-5.5` | 固定模型或自动选择最快可用模型 |
| `TCP_TUNE_AI_TIMEOUT` | `90` | AI 请求超时秒数 |
| `TCP_TUNE_AI_MAX_ROUNDS` | `5` | AI 自动调参最大轮数 |

运行状态：

```text
/var/lib/tcp-tune/
├── backups/
├── initial-defaults/
├── initial-defaults.path
├── profiles/
├── rolled-back/
├── sessions/
├── agent-PORT.pid
├── agent-PORT.token
├── agent-PORT.url
└── iperf3-PORT.pid
```

AI/IPv6 适配文件：

```text
VPS:     /etc/sysctl.d/98-tcp-ipv6-openwrt-peer.conf
OpenWrt: /etc/sysctl.d/zz-tcp-ipv6-local-peer.conf
```

## 7. 安全设计

- Agent 默认临时运行，不注册系统服务。
- token 随机生成，仅用于本次会话。
- TTL 到期后 Agent 拒绝新操作。
- 写入类操作只接受白名单 endpoint。
- Python Agent 只执行固定脚本参数，不接受任意 shell 命令。
- AI 决策只允许结构化 JSON，不接受任意 shell 命令。
- AI 可写入参数受白名单和数值上下限限制；OpenWrt 侧不会修改防火墙、WAN、DNS、DHCP、代理服务或路由。
- PMTU、P4 多流、qdisc drop/backlog delta 只作为诊断证据；MTU、TBF/HTB、qos-agent、策略路由和多 peer 并发测试不属于默认自动优化动作。
- 调参报告写入 `/var/lib/tcp-tune/profiles/latest.md`，只记录脱敏上下文、P1/P4、PMTU、qdisc delta、参数摘要、备份路径和保留/回滚原因。
- Ctrl+C、菜单停止和 `/stop` 会清理本工具创建的 pid、token、连接 URL 和临时 Agent 脚本，并保留日志和参数备份。
- 不停止没有 pid 记录的长期 iperf3，避免误杀用户自建服务。

## 8. OpenWrt 说明

OpenWrt 默认作为客户端使用：

- 不强制安装 Python。
- 只要求 Shell、curl、iperf3、sysctl。
- 缺少 iperf3/curl 时支持 `--yes` 自动安装。
- 缺少 `tc` 时只给建议，不阻断基础测速。
- 智能推荐受内存护栏限制。
- 默认不修改 forwarding，不改变路由器角色。
- `local-minimal` 只允许写入 `tcp_mtu_probing`、`tcp_slow_start_after_idle`、`tcp_notsent_lowat`、`tcp_limit_output_bytes`。

## 9. 测试策略

基础静态检查：

```sh
bash -n tcp-tune.sh
powershell -NoProfile -Command '...PSParser...'
```

本地非破坏性检查：

```sh
sh tcp-tune.sh doctor
sh tcp-tune.sh profiles
sh tcp-tune.sh recommend --local-mbps 1000 --peer-mbps 1000 --rtt-ms 100 --memory-mb 1024
sh tcp-tune.sh --dry-run server --public-url http://1.2.3.4:39188
```

集成测试：

- VPS 运行 `server --ttl 120`
- OpenWrt 运行 `client`
- 验证 `/status`、`/events`、`/test`、`/report`、`/stop`
- 验证服务端写入端点返回 `403`
- 验证 `ai-benchmark-models` 默认可通过项目 AI 网关运行，私有直连模式缺少 Key 时明确失败
- 验证 AI 返回非法 JSON、未知字段或越界参数时不会写入
- 验证 `vps-adapt` 和 `local-minimal` 写入前创建 `/var/lib/tcp-tune/manual-*` 备份
- 验证 AI 调整后吞吐下降超过 5% 或重传明显升高时自动回滚
- 验证 Ctrl+C、客户端停止或 TTL 到期后无 Agent/iperf3 残留
- 验证 `rollback` 恢复修改前 live sysctl 快照

## 10. 架构决策

### 决策：服务端承担 HTTP Agent

OpenWrt 常见设备资源有限，默认不安装 Python。公网 VPS 更适合承担 Agent，因此主路径是 VPS `server`、OpenWrt/PC `client`。

### 决策：使用临时 HTTP + token

SSH 控制不适合一键配对体验。临时 HTTP Agent 使用随机 token 和 TTL，适合短时可信调优会话。

### 决策：默认不修改 forwarding

工具只调 TCP/队列/缓冲相关参数，不默认开启或关闭 `ip_forward`，避免改变用户网络拓扑。

### 决策：只停止本工具创建的进程

安全清理只依赖 pid 文件，不主动停止未记录的长期 iperf3 服务，避免误杀用户已有测试服务。

### 决策：AI 直接执行但受白名单约束

AI 参与运行时自动调参，但不能输出任意命令。脚本只接受结构化字段，并在执行前做枚举和数值边界校验。默认策略是 VPS 侧承担主要适配，OpenWrt 侧只做最小必要修正。
