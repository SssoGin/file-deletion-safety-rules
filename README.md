# 文件安全删除规则

面向 Windows 上 Codex、Claude 和 OpenCode 的可移植文件删除安全规则包。

本包提供三种明确模式：

- 普通“删除/清理/移除”：移入同卷隔离目录，可恢复但不释放空间；
- “移到回收站”：仅在真实交互式 Windows 用户会话、当前身份与同 Session Explorer 一致且所有回收站证据可验证时执行；
- “永久删除/彻底删除/清理空间”：必须展示精确清单并再次确认，不进入回收站且不可由 Agent 恢复。

## 重要兼容性边界

自动回收站是环境相关能力。在 Agent 沙箱、服务会话、无同 Session Explorer、身份不一致、网络路径或回收站策略无法验证时，本模式会安全停止。这不是安装失败，也不会改用永久删除命令。

本包不包含桌面桥接、常驻服务、计划任务、管理员提权、网络监听或永久删除回退。

## 目录

```text
policy/file-deletion-safety.md       完整策略
helpers/Recycle-Bin-Only.ps1         固定哈希回收站 helper
adapters/*.md                        三端全局规则片段
scripts/Install-FileDeletionSafetyRules.ps1  预览/安装
scripts/Verify-FileDeletionSafetyRules.ps1   安装验证
scripts/Uninstall-FileDeletionSafetyRules.ps1 预览/卸载
tests/Test-Package.ps1               静态包验证
manifest.json                        安装清单
```

## 获取

```powershell
git clone https://github.com/SssoGin/file-deletion-safety-rules.git
Set-Location .\file-deletion-safety-rules
```

也可以从 GitHub 下载源码 ZIP，解压后让 Agent 先运行安装预览。

## 让 Agent 安装

先让 Agent 运行预览，不允许直接应用：

```powershell
pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All
```

检查目标文件、共享策略位置和将插入的完整规则块。用户明确确认后再运行：

```powershell
pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Apply -Tool All
pwsh -NoProfile -File .\scripts\Verify-FileDeletionSafetyRules.ps1 -Tool All
```

可将 `All` 改为 `Codex`、`Claude` 或 `OpenCode`。安装器会从当前用户配置目录动态解析路径，不包含发布者的用户名或盘符。

## 卸载

默认只预览：

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All
```

明确确认后使用 `-Mode Apply`。默认只移除本包的 managed block；只有显式增加 `-RemoveSharedFiles` 且三端均已无 managed block 时，才移除共享策略和 helper。

## 回收站失败时

`EXPLORER_NOT_FOUND`、`SESSION_MISMATCH`、`IDENTITY_MISMATCH` 和 `IDENTITY_UNVERIFIABLE` 都表示当前 Agent 环境不支持自动回收站。Agent 必须保留原始错误码，明确说明没有移动任何文件，并让用户选择手动使用资源管理器或明确改用隔离模式。

## 许可证

本项目采用 MIT License，详见 `LICENSE`。
