# Windows PowerShell 源码

根目录 `tcp-tune.ps1` 是面向一键运行的单文件发行版，由本目录模块按固定顺序生成。

- `00-entry.ps1`：参数、版本和公共常量。
- `10-ui.ps1`：轻量终端显示与格式化。
- `20-runtime.ps1`：固定版本 iperf3 的安全安装和依赖检查。
- `30-network.ps1`：Agent、地址、测速和 iperf3 JSON 解析。
- `50-cli.ps1`：Windows 链路评估、菜单和命令分发。

修改模块后运行：

```powershell
& .\scripts\build-powershell.ps1
& .\scripts\build-powershell.ps1 -Check
```

自动下载 manifest 的 SHA256 未经维护者确认时会安全失败，不会绕过校验。
