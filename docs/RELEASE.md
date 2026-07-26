# 发布流程

项目使用语义化版本号和维护者创建的 `v*` Git tag 发布。GitHub Actions 不会自动创建 tag，也不会自动修改 GitHub 仓库设置。

## 发布前

1. 确认目标版本已写入代码和 `CHANGELOG.md`，发布日期与 Breaking Changes 真实准确。
2. 运行完整本地检查：

   ```sh
   sh scripts/check-generated.sh
   bash -n tcp-tune.sh
   dash -n tcp-tune.sh
   busybox ash -n tcp-tune.sh
   shellcheck -s sh tcp-tune.sh
   sh tests/shell/run.sh
   sh tests/agent/run.sh
   npm ci
   npm test
   ```

3. 在 Windows PowerShell 5.1 和 PowerShell 7 中运行 Parser 与 Pester。
4. 检查 `git diff --check`、生成文件一致性和敏感信息；确认没有 token、API Key、Cookie、密码、私钥、真实服务器地址、临时日志或测试目录。
5. 合并并等待普通 CI 全部成功。

## 创建发布

维护者在本地显式创建并推送 annotated tag：

```sh
git tag -a v0.3.0 -m "TCP-optimization v0.3.0"
git push origin v0.3.0
```

此操作会触发 Release 工作流。工作流重新执行静态检查和测试，再生成：

```text
tcp-tune.sh
tcp-tune.ps1
tcp-optimization-v0.3.0.tar.gz
tcp-optimization-v0.3.0.zip
SHA256SUMS
```

工作流使用 `gh release create` 创建 GitHub Release，不发布 Worker、不部署生产环境，也不改仓库 description/topics。

## 验收

1. 下载同一 Release 的全部资产。
2. 校验：

   ```sh
   sha256sum -c SHA256SUMS
   ```

3. 对单文件执行语法检查和 `--help`/只读命令烟测。
4. 检查 Release Notes 的 Added、Changed、Fixed、Security、Breaking Changes、Upgrade Notes 和 Known Issues。
5. 确认一键运行 URL 仍指向兼容的根目录脚本。

## 回滚发布

发现问题时先在 GitHub 上将 Release 标记为 pre-release 或撤下有问题的资产，并发布修复版本；不要覆盖既有 tag 或静默替换相同文件名的资产。若 tag 尚未被其他用户使用，可在明确确认后按项目 Git 规则处理；默认不自动删除远端 tag。

## 仓库元数据建议

Description：

```text
双端 TCP 测速、诊断与可回滚调优工具，支持 Linux、OpenWrt、macOS 和 Windows。
```

Topics：

```text
tcp-optimization, openwrt, linux, iperf3, bbr, network-tuning, powershell, cloudflare-workers
```

这些内容仅为建议，需要维护者在 GitHub 设置中手动确认。
