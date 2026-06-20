# ARCHITECTURE.md

## 1. 项目概述

`TCP-optimization` 是一个双端 TCP 调优工具，仓库地址：

```text
https://github.com/10000ge10000/TCP-optimization
```

它面向公网 VPS 与 OpenWrt / Linux / macOS / Windows 客户端，通过临时 HTTP Agent 和 iperf3 测试结果完成双端状态交换、测速、参数推荐、自动调优和回滚。

核心体验：

```text
服务端运行 server
  -> 自动安装依赖
  -> 启动 Agent + iperf3
  -> 输出客户端命令
客户端运行 client
  -> 自动安装依赖
  -> 上报状态
  -> 进入客户端菜单
双方通过菜单进行测速、优化、查看过程和停止会话
```

## 2. 技术栈

- Shell：Linux/OpenWrt/macOS 主脚本 `tcp-tune.sh`
- PowerShell：Windows 客户端 `tcp-tune.ps1`
- Python 标准库：服务端临时 HTTP Agent
- iperf3：上传/下载方向测速
- sysctl：Linux/OpenWrt TCP 参数写入
- curl/wget：下载脚本和调用 Agent

## 3. 核心模块职责

`tcp-tune.sh`：

- 系统识别：识别 OpenWrt、Debian/Ubuntu、RHEL 系、macOS。
- 依赖安装：按包管理器自动安装 iperf3、curl、python3。
- 服务端模式：启动 Agent、iperf3，输出客户端命令并进入服务端菜单。
- 客户端模式：上报状态，进入客户端菜单。
- 智能推荐：按 BDP、RTT、内存和目标生成 TCP 参数。
- 自动优化：按 iperf3 Retr / 吞吐结果迭代调整参数。
- 备份回滚：每次写入前保存 live sysctl 快照。
- 安全清理：停止本工具创建并记录 pid 的临时 Agent/iperf3。

`tcp-tune.ps1`：

- Windows 状态检测。
- 自动尝试安装 iperf3。
- 连接服务端 Agent，上报状态。
- 提供 Windows 客户端菜单和 iperf3 测试。
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
  -> server_menu
```

客户端：

```text
client
  -> detect_os
  -> install_runtime_deps
  -> POST /report
  -> client_menu
  -> auto/test/status/events/stop
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

## 5. Agent 协议

Agent 是临时 HTTP 服务，默认监听 `0.0.0.0:39188`，通过随机 token 校验。

端点：

| 方法 | 路径 | 作用 |
|---|---|---|
| `GET` | `/status` | 获取服务端状态 |
| `GET` | `/events` | 获取事件和客户端上报 |
| `GET` | `/state` | 获取原始 Agent 状态 |
| `POST` | `/report` | 客户端上报状态或测速结果 |
| `POST` | `/test` | 触发服务端 iperf3 测试 |
| `POST` | `/optimize` | 触发服务端本机自动优化 |
| `POST` | `/apply-profile` | 应用服务端预设 |
| `POST` | `/apply-buffers` | 应用服务端 buffer 参数 |
| `POST` | `/stop` | 停止服务端会话 |

所有端点都必须通过请求头 `X-TCP-Tune-Token` 或 query token 校验。文档和日志不应泄露 token。

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

运行状态：

```text
/var/lib/tcp-tune/
├── backups/
├── rolled-back/
├── sessions/
├── agent-PORT.pid
├── agent-PORT.token
├── agent-PORT.url
└── iperf3-PORT.pid
```

## 7. 安全设计

- Agent 默认临时运行，不注册系统服务。
- token 随机生成，仅用于本次会话。
- TTL 到期后 Agent 拒绝新操作。
- 写入类操作只接受白名单 endpoint。
- Python Agent 只执行固定脚本参数，不接受任意 shell 命令。
- Ctrl+C、菜单停止和 `/stop` 会清理本工具创建的 pid。
- 不停止没有 pid 记录的长期 iperf3，避免误杀用户自建服务。

## 8. OpenWrt 说明

OpenWrt 默认作为客户端使用：

- 不强制安装 Python。
- 只要求 Shell、curl、iperf3、sysctl。
- 缺少 iperf3/curl 时支持 `--yes` 自动安装。
- 缺少 `tc` 时只给建议，不阻断基础测速。
- 智能推荐受内存护栏限制。
- 默认不修改 forwarding，不改变路由器角色。

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
- 验证 `/status`、`/events`、`/test`、`/optimize`、`/stop`
- 验证 Ctrl+C 或菜单停止后无 Agent/iperf3 残留
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
