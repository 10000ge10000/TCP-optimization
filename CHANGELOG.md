# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

尚无未发布变更。

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
[0.2.0]: https://github.com/10000ge10000/TCP-optimization/releases/tag/v0.2.0
