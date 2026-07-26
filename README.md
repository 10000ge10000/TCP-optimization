# TCP-optimization

[![Blog](https://img.shields.io/badge/Blog-910501.xyz-orange)](https://blog.910501.xyz/)
[![Bilibili](https://img.shields.io/badge/B%E7%AB%99-59438380-00a1d6?logo=bilibili)](https://space.bilibili.com/59438380)
[![YouTube](https://img.shields.io/badge/YouTube-10000%20AI%20Share-ff0000?logo=youtube&logoColor=white)](https://www.youtube.com/channel/UCqgvZnCN9-9pZcL4SWxmnDw)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

TCP-optimization 是一个双端 TCP 调优脚本，用来在 VPS 和客户端之间做真实测速、自动调参和安全回滚。

它的目标很简单：

- 服务端默认只负责监听、测速和展示状态；“恢复默认值”只会恢复服务端启动时记录的首次快照。
- 客户端负责本机优化，例如 OpenWrt、Linux、macOS、Windows。
- 服务端需要 Python3；OpenWrt 客户端不强制安装 Python。
- 所有修改都有备份，退出时会清理临时 Agent 和 iperf3。

<table>
  <tr>
    <td width="50%" align="center">
      <strong>服务端监控</strong><br>
      <img src="server-dashboard.png" alt="TCP-optimization server dashboard" width="100%">
    </td>
    <td width="50%" align="center">
      <strong>客户端面板</strong><br>
      <img src="client-dashboard.png" alt="TCP-optimization client dashboard" width="100%">
    </td>
  </tr>
</table>

## 特性

- 双端通讯：服务端启动后给出客户端连接命令。
- 自动依赖：服务端自动检测 Python3/iperf3/curl，OpenWrt 客户端只需要 iperf3/curl/sysctl。
- 受控基础项：可用的 BBR 与 FQ/fq_codel 只作为事务候选，必须经过备份、加载验证和复测后才保留。
- 预制参数：按 RTT 和链路距离提供五档 TCP 参数，写入前会先检测并推荐。
- 三种确定性优化：重传优先、吞吐优先、快速起速。
- 高级链路诊断：只读采集角色、协议、PMTU、qdisc drop/backlog、P1/P4 对比，不默认写 MTU/TC。
- OpenWrt 轻量支持：OpenWrt 端不要求 python3。
- 安全清理：Ctrl+C 或菜单停止会清理本工具创建的 Agent/iperf3。
- 回滚备份：每次写入参数前都会保存备份，客户端首次运行会记录本机与服务端的默认快照。

## 快速开始

### 1. 服务端运行

在 VPS 上运行：

```sh
curl -fsSL https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main/tcp-tune.sh | sudo sh -s -- --yes server
```

> 直接管道执行 main 分支脚本无法校验完整性。对安全要求较高的环境，建议改用固定版本的 Release 资产并先校验哈希：
>
> ```sh
> curl -fsSLO https://github.com/10000ge10000/TCP-optimization/releases/latest/download/tcp-tune.sh
> curl -fsSLO https://github.com/10000ge10000/TCP-optimization/releases/latest/download/SHA256SUMS
> sha256sum -c SHA256SUMS --ignore-missing
> sudo sh tcp-tune.sh --yes server
> ```

服务端启动后会显示 OpenWrt/Linux/macOS/Windows 客户端命令。

### 2. 客户端运行

复制服务端输出的客户端命令，在 OpenWrt 或本机运行即可。

已有脚本时也可以这样运行：

```sh
sh tcp-tune.sh --yes client --peer http://SERVER:39188 --token TOKEN --iperf-port 5201
```

多用户主机上 `--token` 会进入 shell history 与进程参数，可改用环境变量：

```sh
export TCP_TUNE_TOKEN=TOKEN
sh tcp-tune.sh --yes client --peer http://SERVER:39188 --iperf-port 5201
```

Windows PowerShell：

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main/tcp-tune.ps1 -OutFile tcp-tune.ps1
.\tcp-tune.ps1 client -Peer http://SERVER:39188 -Token TOKEN -IperfPort 5201 -Direction download -Yes
```

Windows 无 winget/choco/scoop 时，脚本会把 iperf3 下载到用户缓存目录，不写系统目录。自动下载的 iperf3 来自社区构建仓库 [ar51an/iperf3-win-builds](https://github.com/ar51an/iperf3-win-builds)（固定 3.18 版本，下载后强制校验内置 SHA256，不匹配即失败）；企业环境可预装 iperf3 跳过自动下载。

## 平台能力

| 平台 | 服务端 | 测速/诊断 | 自动写入 TCP 参数 | 说明 |
|---|---:|---:|---:|---|
| Linux VPS | 支持 | 支持 | 支持 | 写入项目管理的 sysctl 文件，必须备份、复测并可回滚 |
| OpenWrt | 客户端为主 | 支持 | 最小白名单 | 不强制安装 Python，不修改网络拓扑或代理配置 |
| macOS | 不推荐 | 支持 | 不支持 | 只读检测、测速和建议，不写 Linux sysctl 参数 |
| Windows | 不支持 | 支持 | 不支持 | PowerShell 单文件客户端，只测速和给出建议 |

`未检测`、`不支持`、`失败` 和数值 `0` 是不同状态；机器可读模式会保留该区别，不用 `0` 代替缺失指标。

## 客户端菜单

```text
[0] 预制参数写入      先检测双端基础信息，再推荐五档参数
[1] 稳定自动优化      规则固定，自动测速迭代
[3] 查看本机状态      系统 / TCP 参数
[4] 查看服务端状态    会话 / 测速服务
[5] 查看过程记录      中文摘要日志
[a] 高级链路诊断      PMTU / qdisc / P1 / P4，只读不写入
[8] iperf3 速度测试   简单测速，不修改参数
[6] 回滚最近修改      恢复最近一次参数写入
[9] 恢复默认值        显示本机 / 服务端首次快照状态
[7] 停止会话并退出    清理 Agent / iperf3
[q] 退出客户端        不停止服务端会话
```

## 预制参数写入

预制参数适合想快速套用成熟 TCP 参数的用户。脚本会先测 RTT、上传/下载、重传、首秒速度和内存，再推荐挡位。

| 挡位 | 建议 RTT | 接收 / 发送 | 说明 |
|---|---:|---|---|
| 近距轻载 | < 30ms | 64MiB / 32MiB | 低延迟链路，优先控制重传 |
| 近距高速 | 30~70ms | 64MiB / 64MiB | 同区域或精品线路 |
| 中距均衡 | 70~130ms | 约 85MiB / 约 41MiB | 跨境中等延迟 |
| 长距增强 | 130~190ms | 约 100MiB / 约 48MiB | 跨海高带宽链路 |
| 远距大带宽 | > 190ms | 约 178MiB / 约 85MiB | 高延迟大带宽，低内存谨慎 |

命令行也可以使用：

```sh
sudo sh tcp-tune.sh apply-profile 中距均衡 --dry-run
sudo sh tcp-tune.sh apply-profile 中距均衡
```

## 优化模式

| 模式 | 适合场景 | 目标 |
|---|---|---|
| 重传优先 | 游戏、语音、远程桌面 | 尽量压低重传 |
| 吞吐优先 | 下载、备份、大文件 | 提升稳定传输速度 |
| 快速起速 | 网页、小文件、短连接 | 缩短连接初期提速时间 |

## 高级诊断依据

默认稳定自动优化仍然只用单 peer、P1 单线程 iperf3 做调参依据。高级链路诊断会额外采集机器角色、关键方向、协议类型、出口接口 MTU、PMTU、qdisc drop/backlog delta，以及 P1/P4 对比，用来判断问题更像本机队列、路径、对端还是上游拥塞。

命令行示例：

```sh
sudo sh tcp-tune.sh advanced-diagnose --host SERVER --machine-role relay --critical-direction both --protocol-class tcp
```

> 注意：高级诊断不修改 MTU、防火墙、路由、TBF/HTB 或 qos-agent。`protocol-class=udp-quic` 时，脚本只输出诊断建议，不默认写 TCP sysctl。

成功保留的自动调参报告会写入：

```text
/var/lib/tcp-tune/profiles/latest.md
```

## OpenWrt 会被修改什么

OpenWrt 端只会做 TCP 相关的最小修改，常见写入位置：

```text
/etc/sysctl.d/99-tcp-tune.conf
/etc/sysctl.d/97-tcp-tune-baseline.conf
/etc/sysctl.d/zz-tcp-ipv6-local-peer.conf
```

自动优化只允许最小 TCP 白名单：

```text
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_limit_output_bytes
```

BBR/qdisc 仅在内核明确支持时作为基础能力处理，并且同样走备份、验证和回滚流程。OpenWrt 已有 `cake`、`fq_codel` 或 `fq` 时优先保留；低内存设备不会默认套用高缓冲预设。

不会自动修改：

```text
防火墙 / WAN / LAN / DNS / DHCP / PPPoE / 代理服务 / OpenClash / Mihomo / Nikki
```

## HTTP Agent 安全边界

HTTP Agent 是临时配对与测速控制面，不是面向公网的长期管理面板：

- 默认使用明文 HTTP，token 以明文头传输，只能防止未授权调用，不能提供传输加密。跨公网使用时应限制安全组/防火墙来源，或通过可信 VPN、SSH 隧道接入。
- 走 VPN/隧道时可设置 `TCP_TUNE_AGENT_BIND` 把 Agent 监听收敛到指定接口地址（默认监听全部接口）。
- 默认只接受请求头 token。把 token 放入 URL 会进入浏览器历史、反向代理或访问日志，因此 query token 仅用于显式开启的短期兼容场景。
- Agent 默认只读；写入类端点拒绝任意 sysctl。唯一例外 `/restore-defaults` 只能恢复服务端启动时记录的首次快照。
- `/test` 只应访问当前配对客户端或显式 allowlist；不要将 Agent 端口暴露给不可信网络。
- token、PID、锁和临时脚本存放在受限状态目录；TTL 到期或正常停止时应主动清理本会话 Agent 与 iperf3。
- 工具只停止自身记录且身份验证通过的进程，不使用宽泛的 `pkill iperf3`。

默认端口为 Agent `39188/TCP` 和 iperf3 `5201/TCP`。如需开放端口，请只允许测试对端地址，并在会话结束后撤销临时规则；本项目不会自动修改防火墙。

## 环境变量

| 变量 | 默认值 | 用途 |
|---|---|---|
| `TCP_TUNE_STATE_DIR` | `/var/lib/tcp-tune` | 状态、备份、会话和报告目录 |
| `TCP_TUNE_SYSCTL_FILE` | `/etc/sysctl.d/99-tcp-tune.conf` | 项目管理的 Linux sysctl 文件 |
| `TCP_TUNE_AGENT_PORT` | `39188` | HTTP Agent 监听端口 |
| `TCP_TUNE_AGENT_BIND` | 空（全部接口） | Agent 监听地址，可收敛到内网/VPN 接口 |
| `TCP_TUNE_TOKEN` | 空 | 客户端 `client`/`join` 的 token 来源，替代 `--token` 避免进入 history |
| `TCP_TUNE_IPERF_PORT` | `5201` | iperf3 测试端口 |
| `TCP_TUNE_SESSION_TTL` | `1800` | 临时会话有效期（秒） |
| `TCP_TUNE_PUBLIC_URL` | 空 | 客户端可访问的 Agent URL |
| `TCP_TUNE_AGENT_TEST_ALLOWLIST` | 空 | `/test` 额外允许的目标，按实现支持的格式填写 |
| `TCP_TUNE_ALLOW_QUERY_TOKEN` | `0` | 临时兼容 query token；不建议开启 |
| `TCP_TUNE_DRY_RUN` | `0` | 只预览，不写系统配置 |
| `NO_COLOR` | 未设置 | 禁用 ANSI 颜色 |

token 和密码只能通过环境变量或 GitHub Secrets 提供，不要写入脚本、配置、命令历史或 Issue。

## 开发与测试

真实双端测试环境、统计结果、失败注入和未验证项见 [验证报告](docs/VALIDATION.md)。

Shell 采用“源码模块化、发布单文件化”：日常修改 `src/`，通过固定模块清单生成根目录 `tcp-tune.sh`。OpenWrt 用户仍只需下载一个文件。

```sh
sh scripts/build-shell.sh
sh scripts/check-generated.sh
bash -n tcp-tune.sh
dash -n tcp-tune.sh
busybox ash -n tcp-tune.sh
shellcheck -s sh tcp-tune.sh
sh tests/shell/run.sh
sh tests/agent/run.sh
python3 -m unittest discover -s tests/validation -p 'test_*.py'
```

PowerShell：

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\tcp-tune.ps1),
  [ref]$tokens,
  [ref]$errors
) | Out-Null
if ($errors.Count) { $errors; exit 1 }

Invoke-Pester .\tests\powershell
```

测试必须使用模拟 sysctl 和临时状态目录，不得修改 CI 主机的真实网络参数。可用命令以当前分支实际文件为准；完整约束见 [ARCHITECTURE.md](ARCHITECTURE.md) 和 [AGENTS.md](AGENTS.md)。

## 故障排查

- `401/403`：确认 token 通过请求头发送、服务端和客户端属于同一会话，且 TTL 未到期。
- `connection refused`：检查 Agent/iperf3 是否仍在运行、端口是否只对测试端开放；项目不会自动调整防火墙。
- `/test` 拒绝目标：目标必须是已配对客户端或显式 allowlist，域名解析结果也必须通过校验。
- iperf3 指标为空：保留 `unknown`，检查双方 iperf3 版本、方向、源地址绑定和 JSON 输出，不要把缺失值当作 0。
- sysctl 加载失败：查看事务日志和备份路径；参数不存在会标记为 `unsupported`，验证失败则应自动恢复。
- 性能复测退化：新参数不会保留；链路抖动较大时增加测试次数，不要继续盲目放大缓冲。
- Windows 下载失败：检查代理、TLS、GitHub 限流和 SHA256 提示；哈希或压缩包结构不匹配时不要绕过校验。

## 发布与校验

版本遵循语义化版本号。维护者创建 `v*` tag 后，Release 工作流才会构建单文件脚本、发布包和 `SHA256SUMS`；工作流不会自动创建 tag。发布流程见 [docs/RELEASE.md](docs/RELEASE.md)，变更记录见 [CHANGELOG.md](CHANGELOG.md)。

下载 Release 资产后可校验：

```sh
sha256sum -c SHA256SUMS
```

## 回滚

最近一次修改可以回滚：

```sh
sudo sh tcp-tune.sh rollback
```

`rollback` 会同时查找普通参数写入备份和手动适配产生的 `manual-*` 备份，并尽量恢复写入前的运行时 sysctl 值。

客户端菜单里的“恢复默认值”用于回到首次运行记录的双端快照：客户端恢复本机首次快照，同时通过带 token 的固定 Agent 端点请求服务端恢复启动时快照。它只处理本工具管理的 TCP/sysctl 参数，不修改防火墙、DNS、代理或路由策略。

备份目录通常在：

```text
/var/lib/tcp-tune/backups
/var/lib/tcp-tune/manual-*
/var/lib/tcp-tune/initial-defaults
```

## 清理

停止临时 Agent 和 iperf3：

```sh
sudo sh tcp-tune.sh stop-agent
```

本工具只停止自己记录 pid 的临时进程，不会主动杀掉用户已有的长期 iperf3 服务。

## 许可证

MIT
