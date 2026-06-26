# TCP-optimization

仓库地址：<https://github.com/10000ge10000/TCP-optimization>

`TCP-optimization` 是一个双端 TCP 调优工具。它面向 VPS + OpenWrt / Linux / macOS / Windows 客户端的真实链路测试：服务端一条命令启动并默认保持只读监控，客户端复制命令加入，通过临时 Agent 通讯，用 iperf3 测速结果驱动 TCP 参数优化。显式启用 AI/适配命令时，工具支持“VPS 为主、OpenWrt 少量必要修改”的 IPv6 链路适配。

## 最短使用路径

### 1. 服务端运行

在公网 VPS 上运行：

```sh
curl -fsSL https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main/tcp-tune.sh -o tcp-tune.sh
chmod +x tcp-tune.sh
sudo sh tcp-tune.sh --yes server
```

脚本会自动检查并安装依赖，启动：

- 临时 HTTP Agent，默认端口 `39188`
- iperf3 server，默认端口 `5201`
- 随机 token
- OpenWrt / Linux / macOS / Windows 客户端运行命令

服务端不会进入操作菜单，也不会修改本机 TCP 参数。窗口会持续显示已接入客户端、最近测速结果和事件；按 `Ctrl+C`、客户端请求停止或 TTL 到期时，脚本会清理 Agent、iperf3 和会话凭据后退出。

如果自动识别的公网地址不准，可以手动指定：

```sh
sudo sh tcp-tune.sh --yes server --public-url http://你的公网IP或域名:39188
```

### 2. 客户端运行

服务端会输出三类命令。

OpenWrt / Linux / macOS 一键运行：

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

服务端启动完成后会显示只读监控面板和客户端连接命令。客户端连接后会进入客户端菜单。
即使使用 `curl | sh` 这种管道方式运行，菜单也会从当前终端读取输入，不会因为标准输入被脚本流占用而自动退出。

## 菜单能力

服务端没有交互菜单，仅负责：

- 展示各系统客户端运行命令
- 展示已接入客户端、LAN 地址和最近上报时间
- 展示最近测速模式、方向、速率、重传和事件
- 提供临时 Agent 与 iperf3 测速端点
- 在 Ctrl+C、远程停止或 TTL 到期时安全清理

客户端菜单：

```text
1. 开始优化
   - 重传优先：尽量把重传降到 0
   - 吞吐优先：提高稳定传输速率
   - 快速起速：缩短连接初期提速时间
2. 查看本机状态
3. 查看服务端状态
4. 查看过程记录
5. 停止双方会话并退出
0. 退出客户端
```

客户端首页显示本机系统和局域网 IPv4，例如 `OpenWrt · 10.10.10.253`。代理公网地址只用于内部连接，不再作为本机 Host 或 iperf3 主机展示。iperf3 会使用本机局域网地址作为源地址绑定；远端测速目标仍是已连接的服务端，不能把本机 LAN 地址误当成远端目标。

优化过程使用面向用户的摘要：优化模式、测试方向、当前轮次、Mbps/Gbps、重传次数、变化趋势、快速起速的首秒速度、当前调整动作和最终结论。`rmem/wmem`、`tcp_notsent_lowat`、`tcp_limit_output_bytes` 等原始参数不再占据主流程，但仍会写入配置并保留回滚备份。

Windows PowerShell 客户端使用相同的中文菜单和三种模式。Windows 端默认只执行真实链路测试、目标判定和优化建议，不自动写 Windows TCP 栈；Linux/OpenWrt 客户端才会自动保存内核参数。服务端 `server` 模式默认只读，不接受参数写入；只有显式运行 `ai-auto`、`vps-adapt`、`local-minimal` 等本机命令时才会写入受控 sysctl。

自动优化只保留经过下一轮 iperf3 复测的参数。最后一轮不会再写入未经验证的新参数；如果重传、吞吐或首秒速度相对上一轮明显退化，脚本会自动撤销最新调整并保留上一轮更优配置。

客户端与服务端交互稿：[Figma 设计](https://www.figma.com/design/kiyIiPBnkOSSrFqmnU0DJG)。

## 常用命令

环境检查，不写系统：

```sh
sh tcp-tune.sh doctor
```

只安装依赖，不启动服务：

```sh
sudo sh tcp-tune.sh --yes install
```

预览服务端启动，不安装、不启动、不写参数：

```sh
sudo sh tcp-tune.sh --dry-run server --public-url http://1.2.3.4:39188
```

查看状态：

```sh
sh tcp-tune.sh status
```

查看 TCP 参数预设：

```sh
sh tcp-tune.sh profiles
```

智能推荐但不写入：

```sh
sh tcp-tune.sh recommend \
  --local-mbps 1000 \
  --peer-mbps 1000 \
  --rtt-ms 100 \
  --memory-mb 1024 \
  --objective retrans
```

自动优化下载方向：

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

自动优化上传方向：

```sh
sudo sh tcp-tune.sh --yes auto \
  --host 1.2.3.4 \
  --direction upload \
  --objective retrans \
  --target-retr 0 \
  --local-mbps 1000 \
  --peer-mbps 1000 \
  --rtt-ms 100 \
  --rounds 3
```

如果测试目标与本机公网出口相同，脚本现在只提示风险并继续测试；`--allow-same-public-ip` 保留为兼容旧命令的参数：

```sh
--allow-same-public-ip
```

AI 辅助双端调优：

```sh
export NVIDIA_API_KEY="你的 Nvidia API Key"
sudo sh tcp-tune.sh ai-auto \
  --peer 2406:xxxx:xxxx::1 \
  --objective balanced \
  --rounds 5
```

AI 模式会先做 IPv6 单线程上传/下载基线测试，再把脱敏摘要发送到 `NVIDIA_BASE_URL`。模型只能返回结构化 JSON 决策，脚本只执行白名单动作，不允许模型输出任意 shell 命令。

模型自动测速：

```sh
export NVIDIA_API_KEY="你的 Nvidia API Key"
sh tcp-tune.sh ai-benchmark-models
```

默认候选模型使用 NVIDIA Build/OpenAI-compatible 需要的完整模型 ID：

```text
minimaxai/minimax-m3
moonshotai/kimi-k2.6
minimaxai/minimax-m2.7
z-ai/glm-5.1
```

GitHub Actions 中使用：

1. 打开仓库 `Settings` -> `Secrets and variables` -> `Actions`。
2. 推荐在 `Secrets` 中新增 `NVIDIA_API_KEY`。如果只是临时测试，也可以在 `Variables` 中新增同名变量。
3. 进入 `Actions` -> `AI smoke test` -> `Run workflow`，即可让 GitHub Runner 调用 `sh tcp-tune.sh ai-benchmark-models`。

注意：GitHub 的 Secrets/Variables 只会注入到 GitHub Actions 运行环境，不会自动出现在 VPS、OpenWrt 或用户本机。通过 `curl | sh`、SSH、本地脚本运行 AI 模式时，仍需要在那台机器上设置 `NVIDIA_API_KEY` 环境变量。

确定性适配命令：

```sh
# VPS 侧：主要适配本地 OpenWrt 链路，默认 cubic-safe
sudo sh tcp-tune.sh vps-adapt --peer-ipv6 2408:xxxx::1 --profile cubic-safe

# OpenWrt 侧：只做最小本地修正，不碰防火墙、WAN、DNS、DHCP、代理服务
sudo sh tcp-tune.sh local-minimal --ipv6-peer 2406:xxxx::1
```

## TCP 预设

预设使用中文名称，并按距离/延迟从近到远排列。英文别名用于脚本化调用。

| 预设 | 英文别名 | RTT 参考 | 接收上限 | 发送上限 | 适用场景 |
|---|---|---:|---:|---:|---|
| 超近距极速 | `ultra-close` | < 10ms | 32MiB | 32MiB | 同城、同机房、极低延迟 |
| 近距均衡 | `near-balance` | 10~30ms | 64MiB | 32MiB | 近距精品线路，保守非对称 |
| 近距极速 | `near-speed` | 30~60ms | 64MiB | 64MiB | 同区域低延迟，对称大缓冲 |
| 中距穿越 | `mid-cross` | 60~120ms | 约 85MiB | 约 41MiB | 港区跨境、中等 RTT |
| 亚太长距 | `apac-long` | 120~180ms | 约 100MiB | 约 48MiB | 亚太跨海、高带宽 |
| 远距穿透 | `far-punch` | 180~250ms | 约 178MiB | 约 85MiB | 欧美方向、高 RTT 大 BDP |
| 超远距极限 | `ultra-far` | > 250ms | 256MiB | 128MiB | 极远距离、极高延迟 |

英文别名：

```text
ultra-close, near-balance, near-speed, mid-cross, apac-long, far-punch, ultra-far
```

应用预设：

```sh
sudo sh tcp-tune.sh apply-profile 近距极速
```

## 自动安装依赖

Linux/OpenWrt/macOS 主脚本会按系统类型自动处理：

- OpenWrt：`opkg install iperf3 curl`
- Debian / Ubuntu：`apt-get install -y iperf3 curl python3`
- RHEL / Fedora：`dnf/yum install -y iperf3 curl python3`
- macOS：通过 Homebrew 安装 `iperf3`

Windows PowerShell 客户端传入 `-Yes` 时会尝试：

1. `winget`
2. `choco`
3. `scoop`

如果当前系统没有这些包管理器，会明确报错，不会伪装成安装成功。

## 写入位置与回滚

Linux/OpenWrt 参数写入：

```text
/etc/sysctl.d/99-tcp-tune.conf
```

AI/IPv6 双端适配额外写入：

```text
VPS:     /etc/sysctl.d/98-tcp-ipv6-openwrt-peer.conf
OpenWrt: /etc/sysctl.d/zz-tcp-ipv6-local-peer.conf
```

运行状态和备份：

```text
/var/lib/tcp-tune/
```

每次写入前都会保存修改前的 live sysctl 快照。回滚成功后，该备份会移动到：

```text
/var/lib/tcp-tune/rolled-back/
```

回滚最近一次修改：

```sh
sudo sh tcp-tune.sh rollback
```

连续执行可以连续回退多次。

## 安全说明

- `server` 会临时打开 HTTP Agent 端口和 iperf3 端口。
- Agent 使用随机 token，所有写入类接口都必须校验 token。
- token 不要发到公开群聊、日志或截图中。
- 交互终端会显示一次客户端连接命令；输出被重定向到日志时，token 会自动替换为隐藏占位符。
- `server/client` 在 Ctrl+C、菜单停止、远程 `/stop` 时会清理本工具创建的 Agent 和 iperf3。
- 清理时会同步删除会话 token、连接 URL 和临时 Agent 脚本；测速日志和参数备份继续保留。
- 工具只停止自己记录 pid 的临时进程，不会主动误杀用户已有的长期 iperf3 服务。
- 默认 Agent 是 HTTP 明文，只建议用于临时可信调优会话。
- AI 模式只从环境变量读取 `NVIDIA_API_KEY`，不要把 Key 写入脚本、README、`.env` 或命令日志。
- AI 运行时调参是直接执行，但只执行脚本内置白名单动作；不会允许模型修改防火墙、路由、DNS、DHCP、代理服务或执行任意 shell 命令。

停止会话：

```sh
sudo sh tcp-tune.sh stop-agent
```

## 排障

查看环境：

```sh
sh tcp-tune.sh doctor
```

查看监听：

```sh
ss -ltnp | grep -E '39188|5201'
```

查看事件：

```sh
curl -H "X-TCP-Tune-Token: TOKEN" http://SERVER:39188/events
```

OpenWrt 如果缺少 `tc`，脚本会提示安装 `tc-full kmod-ifb kmod-sched-cake`。这不是基础运行必需项，只影响后续更高级的队列优化。
