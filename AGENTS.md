# TCP-optimization 项目规则

## 资料来源与落地

- Omnitt 的配置思路重点在“带宽、延迟、内存、拥塞控制、队列算法”共同决定参数。落地到本项目时，BDP 只作为起点，最终必须再经过内存、目标模式和复测结果约束。
- NodeSeek 相关教程的共同经验是：先确认 BBR/qdisc 基线，再用单线程 iperf3 看真实链路；高重传时优先收缩缓冲和发送队列，吞吐稳定时再小步提高；低延迟链路不应机械追求绝对 0 重传。
- TC、CAKE 或显式限速能压低重传，但会改变链路容量表现。本项目只把它作为明确功能或建议，不在默认自动优化里偷偷启用。
- 这些资料只能转化为可验证规则，不能直接照抄固定参数。每轮写入后必须复测，不符合目标就回滚。

## 调参原则

- 先测速，再调参。任何自动优化都必须用 iperf3 的真实上传、下载、重传和首秒速度作为输入，不能只按预设写参数。
- 默认单线程测试。多线程只能作为容量探测或人工排障选项，不作为默认调参依据。
- BDP 只能作为起点。缓冲区不能照搬超大值，必须受内存、RTT、重传和目标模式约束。
- 服务端模式保持只读监控；客户端和显式 AI/VPS 适配命令才允许写入参数。
- OpenWrt 只允许最小必要修改：`tcp_mtu_probing`、`tcp_slow_start_after_idle`、`tcp_notsent_lowat`、`tcp_limit_output_bytes`，以及基础 BBR/qdisc 能力。不得自动修改防火墙、WAN、DNS、DHCP、代理服务或路由策略。
- OpenWrt 不得强制安装 Python。OpenWrt 路径只依赖 POSIX shell、curl/wget、sysctl、iperf3。
- 写入前必须备份，写入后必须复测。复测退化时自动回滚，不保留未经验证的新参数。

## 目标判定

- 重传优先：核心目标是重传下降或达到目标值。吞吐不能出现明显崩塌；低延迟链路不要机械追求绝对 0 重传。
- 吞吐优先：核心目标是上传/下载总吞吐提升。只有在吞吐提升明显时才允许重传小幅上升；吞吐不涨而重传上升视为失败。
- 快速起速：核心目标是首秒速度提升和队列缩短。优先降低 `tcp_notsent_lowat` 与输出排队，不为峰值吞吐堆大缓冲。

## 参数边界

- Linux/VPS 可以调整拥塞控制、qdisc、rmem/wmem、`tcp_rmem/tcp_wmem`、`tcp_notsent_lowat`、`tcp_limit_output_bytes`。
- 默认基础项：可用时启用 BBR；Linux 用 `fq`，OpenWrt 优先保留 `cake/fq_codel/fq`，否则使用 `fq_codel`。
- `tcp_notsent_lowat` 与 `tcp_limit_output_bytes` 必须按目标模式收敛：
  - 重传优先：收缩排队和缓冲。
  - 吞吐优先：允许较大队列，但必须受上限约束。
  - 快速起速：保持小队列，避免为了峰值速度放大排队。
- TC/CAKE 限速属于强干预。只能作为显式功能或建议，不作为默认自动动作。

## 验证要求

- 修改 `tcp-tune.sh` 后必须运行 `bash -n tcp-tune.sh`。
- 修改 `tcp-tune.ps1` 后必须运行 PowerShell 语法解析检查。
- 涉及调参逻辑时，至少做一次真实或本地 dry-run/烟测，证明菜单、依赖检查、iperf3、回滚路径仍可用。
- 提交前搜索确认没有 API Key、SSH 私钥、密码、真实 token 被写入仓库。
