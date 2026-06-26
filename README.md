# TCP-optimization

双端 TCP 调优脚本。它不是“玄学改参数大全”，而是先跑真实 iperf3，再按测速结果调整。适合 VPS + OpenWrt / Linux / macOS / Windows 的链路测试和 TCP 参数优化。

仓库：<https://github.com/10000ge10000/TCP-optimization>

## 它能干什么

- 服务端一条命令启动，只负责监控、通讯、临时测速。
- 客户端自动安装依赖，连接服务端后进入专属菜单。
- 支持 OpenWrt、Linux、macOS、Windows PowerShell。
- 提供三种优化目标：重传优先、吞吐优先、快速起速。
- 支持中文 TCP 预设，不用盯着一堆 `rmem/wmem` 发呆。
- 支持 AI 辅助调参：NVIDIA API 给建议，脚本只执行白名单参数。
- 每次写入前自动备份，效果不对可以回滚。
- Ctrl+C 或停止会话时会清理本工具创建的 Agent / iperf3，避免端口裸奔。

一句话：它把“测速 -> 判断 -> 改参数 -> 复测 -> 回滚兜底”这套流程自动化了。

## 推荐使用方式

### 1. VPS 服务端

在公网 VPS 上运行：

```sh
curl -fsSL https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main/tcp-tune.sh -o tcp-tune.sh
chmod +x tcp-tune.sh
sudo sh tcp-tune.sh --yes server
```

服务端会自动：

- 安装缺失依赖
- 启动临时 HTTP Agent，默认端口 `39188`
- 启动临时 iperf3，默认端口 `5201`
- 生成客户端运行命令
- 显示客户端在线状态、测速结果和事件

服务端 `server` 模式默认只读，不改 TCP 参数。它更像一个“测速接待员”，不是上来就乱拧系统旋钮。

如果公网地址识别不准：

```sh
sudo sh tcp-tune.sh --yes server --public-url http://你的公网IP或域名:39188
```

### 2. 客户端

服务端会直接打印客户端命令，复制到对应机器运行即可。

OpenWrt / Linux / macOS：

```sh
curl -fsSL https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main/tcp-tune.sh | sh -s -- --yes client --peer http://SERVER:39188 --token TOKEN --iperf-port 5201
```

已有脚本本地运行：

```sh
sudo sh tcp-tune.sh --yes client --peer http://SERVER:39188 --token TOKEN --iperf-port 5201
```

Windows PowerShell：

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main/tcp-tune.ps1 -OutFile tcp-tune.ps1
.\tcp-tune.ps1 client -Peer http://SERVER:39188 -Token TOKEN -IperfPort 5201 -Direction download -Yes
```

客户端菜单会提供：

```text
1. 开始优化
2. 查看本机状态
3. 查看服务端状态
4. 查看过程记录
5. 停止双方会话并退出
0. 退出客户端
```

## 三种优化模式

| 模式 | 适合场景 | 目标 |
|---|---|---|
| 重传优先 | 游戏、语音、远程桌面 | 尽量压低 Retr，优先稳 |
| 吞吐优先 | 下载、备份、大文件 | 在可接受重传下提高速度 |
| 快速起速 | 网页、小文件、短连接 | 让连接初期更快进入状态 |

优化过程会显示 Mbps/Gbps、重传次数、方向、轮次和调整动作。普通用户看结果，高级用户再看细节，不需要开局就被内核参数糊脸。

## AI 辅助调参

AI 模式不是让模型执行 shell 命令。模型只能返回结构化 JSON，脚本再按白名单和上下限校验后落地。

支持的默认候选模型：

```text
minimaxai/minimax-m3
moonshotai/kimi-k2.6
minimaxai/minimax-m2.7
z-ai/glm-5.1
```

本机运行：

```sh
sh tcp-tune.sh ai-benchmark-models
```

AI 自动调参：

```sh
sudo sh tcp-tune.sh ai-auto --peer 2406:xxxx:xxxx::1 --objective balanced --rounds 5
```

如果模型首包慢，可以加大超时：

```sh
TCP_TUNE_AI_TIMEOUT=90 sh tcp-tune.sh ai-benchmark-models
```

GitHub Actions 测试：

1. 打开仓库 `Settings` -> `Secrets and variables` -> `Actions`。
2. 在 `Secrets` 中新增 `NVIDIA_API_KEY`。
3. 进入 `Actions` -> `AI smoke test` -> `Run workflow`。

注意：GitHub Secret 只在 GitHub Actions 里可用。你在 VPS、OpenWrt 或本机运行脚本时，仍然要在那台机器上设置 `NVIDIA_API_KEY`。

### 让所有用户使用项目提供的 AI

项目已经提供默认 AI 中转网关：

```text
https://tcp-optimization-ai-gateway.10454728.workers.dev/v1
```

普通用户不需要配置 NVIDIA Key。脚本会在没有检测到 `NVIDIA_API_KEY` 时自动使用这个网关。

正确架构是：

```text
用户脚本 -> 你的 AI 网关 -> NVIDIA API
```

真实 Key 只在 Cloudflare Worker Secret 里，用户脚本只知道网关地址。网关侧负责模型白名单、请求限制、限流和日志脱敏。

如果你要改成自己的网关：

```sh
export TCP_TUNE_AI_GATEWAY_URL="https://你的网关域名/v1"
sh tcp-tune.sh ai-benchmark-models
```

如果你的网关还需要访问令牌：

```sh
export TCP_TUNE_AI_GATEWAY_URL="https://你的网关域名/v1"
export TCP_TUNE_AI_GATEWAY_TOKEN="网关令牌"
sh tcp-tune.sh ai-benchmark-models
```

如果你想绕过公共网关，也可以自己提供 NVIDIA Key：

```sh
export NVIDIA_API_KEY="你的 NVIDIA API Key"
sh tcp-tune.sh ai-benchmark-models
```

GitHub Secret 只给 GitHub Actions 用，不会自动下发给所有运行脚本的用户。

## VPS + OpenWrt 的推荐策略

如果你是家庭宽带 / 软路由 / OpenWrt 用户，建议策略是：

- VPS 承担主要适配。
- OpenWrt 只做少量必要 TCP 修正。
- 不自动碰防火墙、WAN、DNS、DHCP、代理服务。

确定性命令：

```sh
# VPS 侧：默认更稳的 cubic-safe
sudo sh tcp-tune.sh vps-adapt --peer-ipv6 2408:xxxx::1 --profile cubic-safe

# OpenWrt 侧：只做最小修正
sudo sh tcp-tune.sh local-minimal --ipv6-peer 2406:xxxx::1
```

## TCP 中文预设

| 预设 | 英文别名 | 适用场景 |
|---|---|---|
| 超近距极速 | `ultra-close` | 同城、同机房、极低延迟 |
| 近距均衡 | `near-balance` | 近距精品线路，保守稳定 |
| 近距极速 | `near-speed` | 同区域低延迟，对称大缓冲 |
| 中距穿越 | `mid-cross` | 港区跨境、中等 RTT |
| 亚太长距 | `apac-long` | 亚太跨海、高带宽 |
| 远距穿透 | `far-punch` | 欧美方向、高 RTT |
| 超远距极限 | `ultra-far` | 极远距离、极高延迟 |

查看预设：

```sh
sh tcp-tune.sh profiles
```

应用预设：

```sh
sudo sh tcp-tune.sh apply-profile 近距极速
```

## 常用命令

环境检查，不写参数：

```sh
sh tcp-tune.sh doctor
```

只安装依赖：

```sh
sudo sh tcp-tune.sh --yes install
```

查看状态：

```sh
sh tcp-tune.sh status
```

智能推荐但不写入：

```sh
sh tcp-tune.sh recommend --local-mbps 1000 --peer-mbps 1000 --rtt-ms 100 --memory-mb 1024 --objective retrans
```

自动优化：

```sh
sudo sh tcp-tune.sh --yes auto \
  --host 1.2.3.4 \
  --direction download \
  --objective retrans \
  --target-retr 0 \
  --local-mbps 1000 \
  --peer-mbps 1000 \
  --rtt-ms 100 \
  --rounds 3
```

回滚最近一次修改：

```sh
sudo sh tcp-tune.sh rollback
```

停止本工具创建的临时服务：

```sh
sudo sh tcp-tune.sh stop-agent
```

## 写入位置

普通 TCP 调优：

```text
/etc/sysctl.d/99-tcp-tune.conf
```

AI / IPv6 双端适配：

```text
VPS:     /etc/sysctl.d/98-tcp-ipv6-openwrt-peer.conf
OpenWrt: /etc/sysctl.d/zz-tcp-ipv6-local-peer.conf
```

状态、日志和备份：

```text
/var/lib/tcp-tune/
```

## 安全边界

- `server` 会临时打开 Agent 端口和 iperf3 端口。
- Agent 使用随机 token，请不要把 token 发到公开群聊或截图里。
- Ctrl+C、停止会话或 TTL 到期会清理本工具创建的临时进程。
- 只停止本工具记录 pid 的进程，不误杀你已有的长期 iperf3。
- AI Key 只放在 Cloudflare Worker Secret、环境变量或 GitHub Secret，不要写进脚本、README、`.env` 或日志。
- AI 不能执行任意命令，只能返回受控参数。
- OpenWrt 最小修正不会修改防火墙、WAN、DNS、DHCP、代理服务。

## API Key 风险说明

当前项目代码不会主动泄露 `NVIDIA_API_KEY`：

- 仓库不保存真实 Key。
- workflow 只从 `secrets.NVIDIA_API_KEY` 读取。
- 日志不会打印 Key。
- API 请求只发往 `NVIDIA_BASE_URL`，默认是 `https://integrate.api.nvidia.com/v1`。
- 默认公共 AI 网关运行在 Cloudflare Workers，真实 NVIDIA Key 保存在 Worker Secret 中。
- 网关只允许项目默认模型白名单，并限制请求大小和 `max_tokens`。

仍然要注意：

- 不要把 Key 写进命令截图、README、Issue、日志。
- 不要把 `NVIDIA_API_KEY` 配成 GitHub Repository Variable，使用 Secret。
- 不要把真实 NVIDIA Key 放进公开脚本。公共 AI 必须经过中转网关做限流和审计。
- 如果 Key 曾经在聊天、截图或终端记录中明文出现过，建议轮换一次。

## 排障

查看监听：

```sh
ss -ltnp | grep -E '39188|5201'
```

OpenWrt 如果缺少 `tc`，脚本会提示安装：

```sh
opkg update && opkg install tc-full kmod-ifb kmod-sched-cake
```

这不是基础测速必需项，只影响更高级的队列优化。

## 许可证

MIT
