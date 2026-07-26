# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

尚无未发布变更。

## [0.3.0] - 待发布

### Added

- 新增 AI v2 本地闭环控制器、严格 11 字段决策协议、候选/证据白名单和会话预算。
- 新增默认 5 次、波动时最多 10 次的双向证据采集，以及 30 秒后的独立 holdout 验证。
- Worker 新增 `/v1/tuning/decision`，支持一次结构修复并对推理文本执行唯一合法 JSON 提取。
- 新增 60 个合成 AI 场景、离线评分器、Worker workerd 运行时测试和 Router 实效校验。
- PowerShell 新增 v2 严格决策解析，同时继续保持 Windows 只读评估边界。

### Changed

- AI 不再返回参数值或命令，只能选择本地生成的候选 ID、补测 ID 或停止动作。
- 模型在单次会话中固定，不再用短请求延迟选择调参模型。
- AI 失败默认停止且不写入；确定性稳定优化只能通过 `--fallback stable` 显式启用。
- 版本升级至 `0.3.0`，Worker 测试升级至 Vitest 4 并增加 Cloudflare workerd 本地运行验证。
- AI 模式改为混合控制器：确定性证据负责只读/UDP、零重传、回滚、qdisc、BDP 和首秒比例，模型只处理非显然选择。
- NVIDIA 专用调参调用启用 guided JSON；上游熔断按模型隔离，避免模型切换继承旧熔断状态。
- 多上游模式支持显式优先级；验证环境采用 NVIDIA 首选、Sub2API 对可重试故障兜底。
- AI 扩样只由吞吐 CV 触发；重传和首秒 CV 作为显式证据，并在候选保留时执行目标相关的 20% CV 护栏。

### Security

- Worker 公共模式按来源 IP 而不是未经验证的 Bearer 值限流，避免轮换伪 token 绕过配额。
- 专用调参响应只返回清洗后的严格决策，不泄露上游推理、内部模型名、错误正文或密钥。
- Windows/macOS、UDP/QUIC、未知候选、虚构证据和多重 JSON 决策全部失败关闭。
- 高重传但 qdisc 证据为 `unsupported`/`failed`/`unknown` 时停止候选写入，避免把代理路径或上游拥塞误判为本机队列问题。

### Validation

- 合成参考集通过只代表评分器和标签自洽；原始模型仍未通过结构化准确率验收，详见 `docs/VALIDATION.md`。
- 已完成隔离 staging 上游 A/B：Sub2API 严格 holdout 4/12，NVIDIA 6/12；原始模型均未达标。返工后的混合控制器通过 8/8 协议矩阵、5/5 路径拥塞和 5/5 qdisc 缺失重复测试。
- 已完成 OpenWrt/VPS IPv6 P1 双向 5×20 秒基线、AI 真实停止决策、白名单写入后复测退化回滚及手动回滚；未证明当前链路获得性能提升，24 小时稳定性和生产部署仍未完成。

## [0.2.0] - 待发布

### Added

- 将 Shell 源码按 core、platform、tuning、agent、ai 和 cli 分层，继续生成可一键运行的根目录单文件。
- 增加确定性构建与生成文件一致性检查。
- 增加 Shell、HTTP Agent、PowerShell 和 Worker 的单元及非破坏性集成测试入口。
- 增加 `--json`/`-Json`、非交互和无颜色输出模式，以及规范退出码。
- 增加多次测速中位数、离散度、qdisc delta 和平台内存护栏。
- 增加 tag 驱动的 GitHub Release 流程和 `SHA256SUMS`。

### Changed

- 调优决策明确分为重传优先、吞吐优先和快速起速，并同时考虑吞吐、重传、首秒、RTT、内存及 qdisc 状态。
- BBR/qdisc 和普通 sysctl 写入统一进入备份、逐项加载、实际值验证、复测和回滚事务。
- Windows“自动优化”调整为只读的多轮链路评估，不再暗示修改 Windows TCP 栈。
- README 和架构文档补充平台能力矩阵、HTTP Agent 暴露风险、环境变量、开发测试和发布约束。

### Fixed

- 修复 iperf3 不同 JSON 结构可能导致的方向误判及缺失指标被当作 0 的问题。
- 修复最后一轮参数可能未经下一轮复测即被保留的问题。
- 修复 OpenWrt 普通入口可能越过最小写入白名单的问题。
- 修复回滚可能遗漏原文件状态或把部分恢复失败报告为成功的问题。
- 修复 Windows iperf3 下载缺少固定版本、SHA256 和压缩路径检查的问题。
- 修复 Windows 缺失重传被当作 0、IPv4 bind 用于 IPv6 目标、Agent 拒绝 null 指标以及客户端中断短暂遗留 iperf3 的问题。
- 修复 OpenWrt fallback 解析可能猜错 P4/方向、诊断状态混淆和高级诊断标签被全局变量覆盖的问题。

### Security

- HTTP Agent token 只使用安全随机源，默认只通过请求头传递；query token 降级为显式兼容开关。
- 限制 Agent 请求体、字段、队列、并发和子进程时间；增加会话锁、PID 身份验证、TTL 主动清理和 `/test` 目标约束。
- 使用受限权限状态目录、安全临时文件和原子替换，避免临时文件竞争与符号链接覆盖。
- AI 网关增加可选客户端鉴权、实际 body/schema/成本限制、跨实例限流、并发租约、熔断和上游错误清洗。
- 公共或自定义 AI 网关不再接收 `NVIDIA_API_KEY`；该密钥仅允许发送到明确的 NVIDIA 直连地址。

### Breaking Changes

- 默认不再接受 URL query token。短期兼容可显式设置 `TCP_TUNE_ALLOW_QUERY_TOKEN=1`，调用方应迁移到请求头。
- OpenWrt 自动 sysctl 写入收敛到最小白名单；超出白名单的历史用法不再自动执行。

### Upgrade Notes

- 远程一键运行链接、根脚本名称、已有命令、中文别名和菜单编号保持兼容。
- 自建 Agent 客户端应将 token 改为 `X-TCP-Tune-Token` 或 Bearer 请求头。
- 从源码开发时修改 `src/`，然后运行 `sh scripts/build-shell.sh`，不要直接维护生成的根脚本。
- 发布资产应使用同一 Release 中的 `SHA256SUMS` 校验。

### Test Checklist

- [x] 生成文件可重复且与模块源码一致。
- [x] Shell 通过 bash、dash、BusyBox ash 和 ShellCheck。
- [x] fake sysctl 覆盖成功、部分失败、验证失败和回滚失败。
- [x] Agent 覆盖鉴权、请求体、SSRF、TTL、锁、PID 和清理。
- [x] PowerShell 通过 Parser 与 Pester。
- [x] Worker 通过 mock 上游的 Node/本地 Worker 测试。
- [x] 最终 diff 不含凭据、测试主机、调试代码或临时文件。

[Unreleased]: https://github.com/10000ge10000/TCP-optimization/compare/v0.2.0...HEAD
[0.3.0]: https://github.com/10000ge10000/TCP-optimization/releases/tag/v0.3.0
[0.2.0]: https://github.com/10000ge10000/TCP-optimization/releases/tag/v0.2.0
