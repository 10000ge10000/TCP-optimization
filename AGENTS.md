# TCP-optimization 项目规则

## 参考资料评估与落地

- Omnitt 可借鉴的是成熟同类方案的计算模型：本地带宽、服务端带宽、RTT、内存、拥塞控制、队列算法、爬升倾向共同决定参数。落地到本项目时，BDP 只作为起点，不能照抄其静态 sysctl 输出。
- NodeSeek / BlackSheep 脚本可借鉴的是实操经验：先确认 BBR/qdisc 基线，再用单线程 iperf3 看真实链路；高重传时优先收缩缓冲和发送队列；吞吐稳定时再小步提高。
- NodeSeek / BlackSheep 脚本中不适合直接继承的做法包括：默认直接覆盖 `/etc/sysctl.conf`、默认写 TC/CAKE/HTB 限速、无复测即保留参数、用宽泛 `pkill iperf3` 停止进程。
- iBytebox AI Agent VPS TCP tuning 方案可借鉴的是证据模型：VPS 角色、关键业务方向、协议类型、PMTU、qdisc drop/backlog、P1 单流和 P4 多流差异、回滚报告共同参与判断。不得把它理解成默认自动改 MTU、TBF/HTB 或部署 qos-agent。
- TC、CAKE 或显式限速能压低重传，但会改变链路容量表现。本项目只把它作为明确功能或建议，不在默认自动优化里偷偷启用。
- 所有外部资料只能转化为本项目可验证规则，不能照搬固定参数、站点名称、商家名称、地区缩写或用户原始预设名。

## 调参原则

- 先测速，再调参。任何自动优化都必须用 iperf3 的真实上传、下载、重传和首秒速度作为输入，不能只按预设写参数。
- 默认单线程测试。多线程只能作为容量探测或人工排障选项，不作为默认调参依据。
- P4 多流测试、PMTU 探测和 qdisc drop/backlog delta 只属于高级诊断证据；默认稳定自动优化不能因为这些诊断项而偷偷扩大干预范围。
- 调参前必须采集这些输入：RTT、单线程 iperf3 上传/下载速率、上传/下载重传、首秒速度、内存、当前拥塞控制、当前 qdisc、当前 `rmem/wmem`、当前 `tcp_notsent_lowat`、当前 `tcp_limit_output_bytes`。
- 高级诊断可以额外采集：`machine_role`、`critical_direction`、`protocol_class`、PMTU、出口接口 MTU、qdisc drop/backlog delta、P1/P4 对比。`proxy_software` 和 `traffic_path` 只进入报告，不参与 shell 命令拼接。
- BDP 只能作为初始估算。有效带宽优先取真实 iperf3 测速值；如果用户输入带宽与实测差异明显，自动逻辑必须以实测为准，并在提示中说明链路可能受限。
- 缓冲区不能照搬超大值，必须受内存、RTT、重传、目标模式和复测结果约束。低内存设备必须主动下调推荐挡位。
- 服务端模式默认保持只读监控；唯一例外是带 token 的 `restore-defaults` 固定端点只能恢复服务端首次启动时记录的 TCP/sysctl 快照，不能接受任意参数写入。
- OpenWrt 只允许最小必要修改：`tcp_mtu_probing`、`tcp_slow_start_after_idle`、`tcp_notsent_lowat`、`tcp_limit_output_bytes`，以及基础 BBR/qdisc 能力。不得自动修改防火墙、WAN、DNS、DHCP、代理服务或路由策略。
- OpenWrt 不得强制安装 Python。OpenWrt 路径只依赖 POSIX shell、curl/wget、sysctl、iperf3。
- 写入前必须备份，写入后必须复测。复测退化时自动回滚，不保留未经验证的新参数。

## 计算逻辑

- 计算顺序必须是：采集基线 -> 估算 BDP -> 按内存与平台约束收敛 -> 按目标模式调整 -> 写入前备份 -> 写入后复测 -> 根据结果保留或回滚。
- BDP 估算应使用双端瓶颈带宽和 RTT，但瓶颈带宽优先来自 iperf3 单线程实测，而不是用户填写值或网卡标称值。
- `rmem/wmem` 上限可以按 BDP 倍数扩展，但必须设置平台上限；低内存 OpenWrt 不允许默认推荐高缓冲挡位。
- `tcp_notsent_lowat` 与 `tcp_limit_output_bytes` 是控制发送排队的核心旋钮，必须随目标模式收敛，不能只放大 `rmem/wmem`。
- 拥塞控制和 qdisc 是基础项，不是万能修复。可用时优先 BBR + `fq`；OpenWrt 已有 `cake/fq_codel/fq` 时优先尊重现有队列能力。
- 如果高重传来自链路质量、运营商限速、跨境抖动或晚高峰拥塞，脚本只能给出可验证建议，不应继续堆大缓冲制造伪优化。
- 如果重传高但 qdisc drop/backlog delta 为 0，应提示更可能是路径、对端或上游拥塞，不能继续盲目放大 buffer。
- 如果 `protocol_class=udp-quic`，TCP buffer 调整只能作为间接建议；默认不写 TCP sysctl，应优先做 PMTU/qdisc/CPU 诊断。

## 预制参数规则

- 预制参数名称必须是项目自己的中文语义名称，不显示来源站点、商家、地区缩写或用户提供的原始名称。
- 预制参数只能写入本项目管理的 sysctl 文件，不直接覆盖 `/etc/sysctl.conf`。
- 每个预设必须说明适用 RTT、接收/发送缓冲、内存风险和回滚方式。
- 预制参数写入必须走统一备份、加载、失败回滚流程，不能绕过 `backup_state` / `rollback`。
- 低内存 OpenWrt 不默认推荐高缓冲挡位；Windows 只评估和建议，不自动写 TCP 栈。

## 目标判定

- `retrans` / 重传优先：核心目标是重传下降或达到目标值。优先收缩发送队列和过大缓冲；吞吐不能明显崩塌；低延迟链路不要机械追求绝对 0 重传。
- `throughput` / 吞吐优先：核心目标是上传/下载总吞吐提升。只有在吞吐明显提升时才允许重传小幅上升；吞吐不涨而重传上升视为失败。
- `startup` / 快速起速：核心目标是首秒速度提升和队列缩短。优先降低 `tcp_notsent_lowat` 与输出排队，不为峰值吞吐堆大缓冲。
- 每轮判定必须同时看吞吐、重传和首秒速度。单个指标改善但目标指标退化时，不能直接宣称优化成功。

## 参数边界

- Linux/VPS 可以调整拥塞控制、qdisc、rmem/wmem、`tcp_rmem/tcp_wmem`、`tcp_notsent_lowat`、`tcp_limit_output_bytes`。
- OpenWrt 只允许最小白名单：`tcp_mtu_probing`、`tcp_slow_start_after_idle`、`tcp_notsent_lowat`、`tcp_limit_output_bytes`，以及基础 BBR/qdisc 能力。
- Windows 只做测速、评估和建议，不默认写入系统 TCP 栈。
- 默认基础项：可用时启用 BBR；Linux 用 `fq`，OpenWrt 优先保留 `cake/fq_codel/fq`，否则使用 `fq_codel`。
- `tcp_notsent_lowat` 与 `tcp_limit_output_bytes` 必须按目标模式收敛：
  - 重传优先：收缩排队和缓冲。
  - 吞吐优先：允许较大队列，但必须受上限约束。
  - 快速起速：保持小队列，避免为了峰值速度放大排队。
- TC/CAKE 限速属于强干预。只能作为显式功能或建议，不作为默认自动动作。
- MTU、TBF/HTB、qos-agent、策略路由和多 peer 并发测试都属于强干预或复杂诊断，不得作为默认自动优化动作。
- 成功保留调参结果后，应写入 `/var/lib/tcp-tune/profiles/latest.md`，记录角色、方向、协议、P1/P4、PMTU、qdisc delta、写入参数、备份路径和保留原因；不得写入 token、密码、SSH 私钥或 Cookie。
- 不得默认直接覆盖 `/etc/sysctl.conf`。项目写入必须使用本项目管理的 sysctl 文件，并保留备份与回滚路径。
- 不得自动修改防火墙、WAN、DNS、DHCP、代理服务、路由策略、forwarding 或用户已有长期 iperf3 服务。

## 验证要求

- 修改 `tcp-tune.sh` 后必须运行 `bash -n tcp-tune.sh`。
- 修改 `tcp-tune.ps1` 后必须运行 PowerShell 语法解析检查。
- 涉及调参逻辑时，至少做一次真实或本地 dry-run/烟测，证明菜单、依赖检查、iperf3、回滚路径仍可用。
- 写入类调参必须验证备份、加载、复测、退化回滚链路；最后一轮不能留下未经复测的新参数。
- 单独修改 `AGENTS.md` 时，不需要运行脚本语法检查；必须读取修改后的 Markdown、检查 `git diff -- AGENTS.md`，并确认没有敏感信息被写入。
- 提交前搜索确认没有 API Key、SSH 私钥、密码、真实 token 被写入仓库。

## 源码与生成文件

- Shell 采用“源码模块化、发布单文件化”。功能源码放在 `src/`，根目录 `tcp-tune.sh` 是自动生成的发行文件。
- 模块依赖方向固定为 `core -> platform -> tuning / agent -> cli`，禁止底层模块反向调用 CLI 或读取菜单输入。
- `src/core` 只能放配置、退出码、通用工具、校验、JSON 和 UI 基础能力，不得执行 Agent、菜单或 sysctl 业务。
- `src/platform` 只实现平台检测、能力矩阵、参数存在性和写入白名单。
- `src/tuning` 的纯计算函数必须接收显式参数并返回结果；不得直接绘制菜单或读取交互输入。
- `src/agent/http_agent.py` 保持独立可测试，构建时嵌入发行脚本；OpenWrt 客户端运行路径仍不得依赖 Python。
- Shell 模块合并顺序由 `scripts/shell-modules.txt` 唯一定义。构建不得加入时间戳、随机值或机器路径，连续两次构建必须字节一致。
- 不得直接手工修改根目录生成脚本后跳过源码同步。修改 Shell 源码后必须重新生成并运行一致性检查。
- PowerShell 若拆分源码，根目录 `tcp-tune.ps1` 仍必须保持可直接下载运行，且源码模块可被 Pester 单独导入测试。

## 开发命令

Shell 构建和静态检查：

```sh
sh scripts/build-shell.sh
sh scripts/check-generated.sh
bash -n tcp-tune.sh
dash -n tcp-tune.sh
busybox ash -n tcp-tune.sh
shellcheck -s sh tcp-tune.sh
```

测试入口：

```sh
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

- CI 测试只能使用临时状态目录、fixtures 和 fake sysctl，不得修改运行器的真实 sysctl、qdisc、网络接口或防火墙。
- `dry-run` 测试必须证明项目管理文件和系统路径均未发生写入。
- iperf3 解析测试必须覆盖多版本 fixtures、上传/下载方向、缺失字段、数值 0 和无效 JSON。
- Agent 测试必须覆盖 header token、query token 兼容开关、请求体上限、SSRF、TTL、锁、PID 身份和只读端点。

## 版本与发布

- 版本号遵循 Semantic Versioning；`CHANGELOG.md` 使用 Added、Changed、Fixed、Security、Breaking Changes 等明确分类。
- CI 权限只读，不依赖任何外部 API Key。
- Release 工作流只能响应维护者创建的 `v*` tag，不得自动创建或推送 tag。
- 发布前必须执行完整测试和生成一致性检查；产物至少包含 Shell、PowerShell、源码压缩包和 `SHA256SUMS`。
- GitHub Actions 使用最小权限；只有 Release job 可以申请 `contents: write`。
- 发布流程不得在日志、产物、Release Notes 或校验文件中包含 token、API Key、密码、Cookie、SSH 私钥或用户测试主机信息。
