# TCP-optimization

仓库地址：<https://github.com/10000ge10000/TCP-optimization>

`TCP-optimization` 是一个双端 TCP 调优工具。它面向 VPS + OpenWrt / Linux / macOS / Windows 客户端的真实链路测试：服务端一条命令启动，客户端复制命令加入，双方通过临时 Agent 通讯，用 iperf3 测速结果驱动 TCP 参数优化。

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

服务端启动完成后会清屏显示会话面板、客户端连接命令和服务端菜单。客户端连接后会进入客户端菜单。
即使使用 `curl | sh` 这种管道方式运行，菜单也会从当前终端读取输入，不会因为标准输入被脚本流占用而自动退出。

## 菜单能力

服务端菜单：

```text
1. 查看服务端状态
2. 查看客户端上报/事件
3. 运行服务端本机优化
4. 重新显示客户端运行命令
5. 停止会话并退出
0. 退出菜单但保留服务
```

客户端菜单：

```text
1. 查看本机状态
2. 下载方向优化（服务端 -> 本机）
3. 上传方向优化（本机 -> 服务端）
4. 查看服务端状态
5. 查看服务端事件
6. 请求服务端优化
7. 通知服务端停止会话并退出
0. 退出客户端
```

优化过程会显示每轮 iperf3 的方向、速率、Retr、写入的 `rmem/wmem`、`tcp_notsent_lowat`、`tcp_limit_output_bytes` 和下一轮调整信息。
跨端优化使用异步任务：Agent 会立即返回任务 ID，客户端持续轮询状态并在完成后显示优化输出，避免长时间 iperf3 测试被代理或反向代理中断 HTTP 连接。

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

如果测试目标与本机公网出口相同，但你确认这是有效链路，可以增加：

```sh
--allow-same-public-ip
```

## TCP 预设

预设使用中文名称，并按参数内容命名。

| 预设 | 接收上限 | 发送上限 | 适用场景 |
|---|---:|---:|---|
| 稳健入门 | 64MiB | 32MiB | 保守非对称，适合首次尝试 |
| 均衡通用 | 64MiB | 64MiB | 默认推荐，适合多数 VPS |
| 中距增强 | 约 85MiB | 约 41MiB | 中等 RTT、中高带宽 |
| 高带宽增强 | 约 100MiB | 约 48MiB | 高带宽跨境链路 |
| 长距大带宽 | 约 178MiB | 约 85MiB | 高 RTT、高 BDP 链路 |

英文别名：

```text
stable, balanced, medium, boost, longhaul
```

应用预设：

```sh
sudo sh tcp-tune.sh apply-profile 均衡通用
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
- `server/client` 在 Ctrl+C、菜单停止、远程 `/stop` 时会清理本工具创建的 Agent 和 iperf3。
- 清理时会同步删除会话 token、连接 URL 和临时 Agent 脚本；测速日志和参数备份继续保留。
- 工具只停止自己记录 pid 的临时进程，不会主动误杀用户已有的长期 iperf3 服务。
- 默认 Agent 是 HTTP 明文，只建议用于临时可信调优会话。

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
