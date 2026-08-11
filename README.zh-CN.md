# 文件安全删除规则

[English](README.md) | **简体中文**

面向 Windows 上 Codex、Claude 和 OpenCode 的可移植文件删除安全规则包。

本包提供三种明确模式：

- 普通“删除/清理/移除”：移入同卷隔离目录，可恢复但不释放空间；
- “移到回收站”：仅在真实交互式 Windows 用户会话、当前身份与同 Session Explorer 一致且所有回收站证据可验证时执行；元数据指纹会绑定相对路径、类型，以及文件长度和文件最后写入时间，用于发现验证与执行之间发生的同大小替换或改名；
- “永久删除/彻底删除/清理空间”：必须展示精确清单并再次确认，不进入回收站且不可由 Agent 恢复。

## 清理确认

所有操作使用固定十行、两列 Markdown 表格的“清理确认”卡。确认请求直接渲染下表，不能放进代码围栏、改成逐行冒号列表或增删字段：

| 项目 | 内容 |
|---|---|
| 清理对象 | 按用途概括的对象名称 |
| 位置 | 规范化顶层绝对路径；非文件对象写可准确识别的位置或标识 |
| 清理范围 | 顶层文件、完整目录、Junction 本身或其他顶层对象的数量 |
| 内容 | 普通文件和目录统计，或非文件对象的领域事实 |
| 占用空间 | 精确字节数和易读单位，或明确说明不实际释放空间 |
| 清理原因 | 本次清理的判断依据 |
| 清理方式 | 模式、具体动作、可恢复性和空间结果 |
| 安全边界 | 链接、Git 本地内容、受保护内容和保留项 |
| 清理结果 | 执行后的预计状态 |
| 恢复方式 | 可用的恢复或重新创建方法；不存在时写“无” |

小范围、中范围和大范围保持这一结构；大范围按本地卷和清理模式拆卡，不把目标藏到第二份文档中。确认指令放在表格之后，不属于卡片字段。

卡片只列规范化后的顶层目标绝对路径，后代文件和目录按数量及大小汇总。Agent 不生成每次清理专用的本地清单，也不用不透明的快照 ID 代替用户作决定所需的信息。上下文切换后如果已确认快照无法完整恢复，必须重新扫描并展示新卡确认。

Git 分支等非文件对象在本规则适用时也使用同一张表，各单元格按已核验事实填写，不额外规定一套固定子字段。`恢复方式` 可以填写从隔离、回收站或备份恢复，也可以填写从已核验的 Git 或构建输入重新创建；没有可用方法时写“无”。

每个 Junction 都要在确认前解析。要清理的真实目标位于所有已列顶层目录之外时，必须作为独立顶层路径列出；真实目标已被某个顶层目录完整覆盖时只汇总一次，不重复列路径或计数。只删除 Junction 入口时，共享真实目录保持不变；用途不明时停止，不提供可确认的卡片。回收站 helper 会拒绝目标树内外的所有 reparse point，因此存在 Junction 时模式 B 不可用；Junction 处理只适用于能够证明边界的模式 A 或模式 C。

## 重要兼容性边界

自动回收站是环境相关能力。在 Agent 沙箱、服务会话、无同 Session Explorer、身份不一致、网络路径或回收站策略无法验证时，本模式会安全停止。这不是安装失败，也不会改用永久删除命令。

本包不包含桌面桥接、常驻服务、计划任务、管理员提权、网络监听或永久删除回退。

## 前置条件

- 安装目标位于 Windows 本地固定卷；
- 安装、验证、卸载和包测试使用 PowerShell 7（`pwsh`）。

回收站 helper 同时保持 Windows PowerShell 5.1 语法兼容，供受限旧环境使用；但本发布对 5.1 只做解析检查，不能把解析通过理解成全部包脚本已获得 5.1 运行时支持。

## 会话开关

文件安全删除规则在每个新聊天或会话中默认是 `ON`。可以直接对 Agent 使用以下命令：

- `关闭文件安全删除规则`：切换为 `OFF`；
- `启用文件安全删除规则`：恢复为 `ON`；
- `查询文件安全删除规则状态`：只报告当前状态，不切换。

语义明确的同义表达也可以触发，例如“关闭删除规则”“启用安全删除规则”。问句、引用、否定句或意图不明确的表述不得切换状态。

`OFF` 仅适用于当前聊天或会话，不写入磁盘，也不跨 Codex、Claude、OpenCode 或其他 Agent 共享。新会话、切换 Agent 或上下文恢复后状态不明确时自动视为 `ON`。切换只影响尚未开始的操作；系统、平台、权限、项目和其他用户规则仍然有效。

## 目录

```text
README.md                              默认英文说明
README.zh-CN.md                        简体中文说明
RELEASE_NOTES.md                       双语发布说明
policy/file-deletion-safety.md       完整策略
helpers/Recycle-Bin-Only.ps1         固定哈希回收站 helper
adapters/*.md                        三端全局规则片段
scripts/Install-FileDeletionSafetyRules.ps1  预览/安装
scripts/Verify-FileDeletionSafetyRules.ps1   安装验证
scripts/Uninstall-FileDeletionSafetyRules.ps1 预览/卸载
tests/Test-Package.ps1               静态及隔离行为验证
manifest.json                        安装清单
```

## 获取

```powershell
git clone https://github.com/SssoGin/file-deletion-safety-rules.git
Set-Location .\file-deletion-safety-rules
```

也可以从 GitHub 下载源码 ZIP，解压后让 Agent 先运行安装预览。

## 让 Agent 安装

先运行预览并保留返回的 `PlanSha256`。Apply 只接受用户看过的同一份计划：

```powershell
$preview = (& pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All | Out-String) | ConvertFrom-Json
$preview | ConvertTo-Json -Depth 14
```

检查目标文件、共享策略位置、将插入的完整规则块和 `PlanSha256`。用户明确确认后，将同一个哈希传给 Apply：

```powershell
pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Apply -Tool All -ExpectedPlanSha256 $preview.PlanSha256
pwsh -NoProfile -File .\scripts\Verify-FileDeletionSafetyRules.ps1 -Tool All
```

可将 `All` 改为 `Codex`、`Claude` 或 `OpenCode`。安装器会从当前用户配置目录动态解析路径，不包含发布者的用户名或盘符。

Preview 与 Apply 之间只要任一计划文件发生变化，Apply 就会在写入前返回 `PLAN_MISMATCH`。多文件操作中途失败时会按相反顺序回滚；原文件保存在 `.file-deletion-safety-rules-backups` 下的事务目录中，失败事务新建的文件也会移到那里，不会永久删除。

安装器、卸载器和验证器会拒绝所选 profile 根与包管理路径之间任何已存在的 reparse point，包括 symbolic link 和 junction；不会沿 profile 子路径进入其他位置。

安装成功后会写入 `.agents/file-deletion-safety-rules.install.json`。该 receipt 绑定包版本、policy/helper 哈希和已安装工具集合。验证器会根据当前包重建预期 receipt 与 managed block，并要求逐字节匹配。

重新安装或升级时，共享 policy、helper 和 receipt 通常必须三者全无或三者都在。三者都在时，安装器会严格解析 receipt，要求其中的 policy/helper 哈希与磁盘文件一致，并要求工具集合与当前精确 managed block 一致。唯一允许的无 receipt 例外是 `manifest.json` 声明的精确 v1.0.0 布局：两个共享文件必须匹配其中声明的 v1.0.0 哈希，并且至少存在一个精确的包 managed block 或受支持的精确未托管 `0.1` adapter 来证明所有权。检测到的每个受支持未托管 adapter 都必须纳入本次迁移；安装器会保留相邻内容，并把它替换成一个 managed block。随后安装器以事务方式规划 policy/helper 更新并创建第一份 receipt。其他半安装、receipt 异常、共享文件被改、managed block 被改、未知无 receipt 文件对或无所有权规则块时，Preview 都会停止。

## 已有未托管规则

安装器只管理由本包 managed marker 包围的规则块。除上面说明的精确无 receipt v1.0.0 迁移外，所选工具配置只要包含 `manifest.json` 列出的不受支持的未托管删除安全规则标题，包括旧 `0.1` 标题或没有 marker 的当前 adapter 标题，Preview 就会在任何写入前失败；一个精确 managed block 内的标题不计为未托管内容。安装器不会解释或修改未知未托管内容，也不会在旁边追加 managed block。

再次运行 Preview 前，应先备份并由用户手工审查、协调未托管规则。managed marker 残缺或重复，或者同一配置中 managed 与不受支持的未托管规则并存时，也会因所有权不明确而安全停止。

## 卸载

默认只预览，并保留卸载计划哈希：

```powershell
$uninstallPreview = (& pwsh -NoProfile -File .\scripts\Uninstall-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All | Out-String) | ConvertFrom-Json
$uninstallPreview | ConvertTo-Json -Depth 14
```

明确确认后应用同一快照：

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-FileDeletionSafetyRules.ps1 -Mode Apply -Tool All -ExpectedPlanSha256 $uninstallPreview.PlanSha256
```

默认只移除本包精确匹配的 managed block。只有确实要同时移除共享 policy、helper 和 receipt 时，才在 Preview 与 Apply 两次命令中都加入 `-RemoveSharedFiles`。三端均无 managed block，且 manifest、receipt、当前文件哈希共同证明所有权时，共享文件才可处理。被移除文件会移动到结果中报告的事务备份，不会永久删除；用户修改过或所有权不明确时卸载停止。

## 包验证与发布身份

运行非生产包测试：

```powershell
pwsh -NoProfile -File .\tests\Test-Package.ps1
```

它会验证全部运行时哈希，用 PowerShell 7 和 Windows PowerShell 5.1 解析包内所有脚本，并在 `.test-profile` 下运行隔离的 helper、安装器、卸载器和验证器 fixture。测试不会使用真实回收站，也不会永久删除 fixture。

`manifest.json` 可以发现 8 个运行时文件的变化，并证明这些文件与当前 manifest 内部一致；但包内哈希一致不能证明发布来源，因为被修改的压缩包可以同时替换文件和记录的哈希。确认来源时，应从本仓库获取包，并另行固定或比对 Git commit 或 Release tag。

## 回收站失败时

`EXPLORER_NOT_FOUND`、`SESSION_MISMATCH`、`IDENTITY_MISMATCH` 和 `IDENTITY_UNVERIFIABLE` 都表示当前 Agent 环境不支持自动回收站。Agent 必须保留原始错误码，明确说明没有移动任何文件，并让用户选择手动使用资源管理器或明确改用隔离模式。

## Releases

版本和发布说明见 [GitHub Releases](https://github.com/SssoGin/file-deletion-safety-rules/releases)。

## 许可证

本项目采用 MIT License，详见 `LICENSE`。
