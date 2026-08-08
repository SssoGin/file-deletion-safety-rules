# 文件安全删除规则

本文件仅在当前会话“文件安全删除规则”为 `ON` 时适用。

本规则适用于 Windows 上由 Agent 参与的删除、清理、移除、回收站操作、永久清空、破坏性覆盖、截断、强制回滚、镜像同步及其他可能造成数据丢失的操作。与其他规则冲突时，采用限制更严格、可恢复性更高的规则。本规则和 helper 主要防止误操作，不是针对蓄意绕过规则的强制访问控制。

## 1. 先判断用户要的是哪一种结果

| 用户表述 | 模式 | Agent 可以做什么 | 是否释放空间 |
|---|---|---|---|
| “清理”“删除”“移除” | A. 隔离 | 把已确认目标移动到其父目录下的 `.deletion-quarantine` | 否 |
| “移到回收站” | B. 自动回收站 | 一次确认后只调用受限 `Recycle-Bin-Only.ps1`，以当前桌面用户身份送入回收站 | 否 |
| “清理空间”“永久删除”“彻底删除” | C. 永久删除 | 展示不可恢复清单并取得一次明确确认后，只删除已确认的精确字面路径 | 是，按实际删除量计算 |

- “清理空间”只表示用户需要真正释放空间，不等于已经确认任何尚未展示的删除清单。
- 用户表述混合、目标不明确或无法可靠分类时，选择破坏性最低的模式并先询问；不得自行升级为永久删除。
- 回收站或隔离目录中的内容仍占用原卷空间。
- 模式 B 只在交互式 Windows 桌面、当前执行身份与同一 Session 的 Explorer 用户 SID 一致、目标卷策略可验证且 helper 完整性通过时可用；其他环境 fail closed。

## 2. 所有模式共同遵守的门禁

### 2.1 发现和执行分开

- 扫描、搜索、筛选、统计和路径展开只能用于生成候选清单，不得边搜索边删除。
- 执行前把目标解析为规范化绝对路径，并展示目标类型、文件数、目录数、总字节数、处理模式和可恢复性。
- 检查空值、未定义值、相对路径、环境变量、通配符、路径解析失败、重复路径，以及清单中同时出现祖先和后代的情况。
- 用户没有看过的目标不得进入执行范围。确认后目标路径、数量、大小、类型或处理模式变化时，停止并重新确认。
- 用户对完整清单的一次明确确认覆盖该快照的执行、验证，以及不改变路径、数量、大小、类型和模式的安全重试；不得为同一快照逐项或重复询问。
- Agent 所在产品、沙箱或操作系统仍可能显示自身权限审批；该审批不是本规则可以跳过的用户授权门禁。

### 2.2 保护范围

- 禁止递归删除磁盘根目录、用户主目录、当前工作区根目录和项目根目录。
- `.git`、`.codex`、`.claude`、`.agents`、`.config`、`.env`、`AppData`、`Windows`、`Program Files`、`ProgramData`、数据库、用户资料、备份、回收站和 `.deletion-quarantine` 默认受保护。
- 用户明确点名受保护内容时，仍须展示具体子项、风险和恢复条件；模糊的“清理磁盘”“删掉没用的东西”不能解除保护。
- Git 工作区内的候选必须先检查 `git status`；未提交修改、未跟踪文件和其他仅存在于本机的文件须单独列出，不得自动判断为垃圾文件。

### 2.3 链接、挂载点和失败处理

- 执行前检查 symbolic link、junction、mount point 和其他 reparse point。
- 默认只处理链接本身，不递归进入链接目标；无法证明所用操作不会跟随链接时，停止。
- 目标不存在、被占用、权限不足、状态漂移或验证失败时，报告精确路径和原因并停止该目标。
- 不得擅自提权、修改 owner/ACL、终止进程、关闭安全软件，或换用更强力、更不可恢复的操作绕过失败。

## 3. 模式 A：普通清理移入同卷隔离目录

### 3.1 隔离位置

- 对每个目标，在目标父目录下使用 `.deletion-quarantine\<batch-id>\<原名称>`。
- `<batch-id>` 使用 UTC 时间和随机后缀，例如 `20260805T130000Z-a1b2c3d4`；每批必须唯一，已存在时不得复用或覆盖。
- 因隔离根位于目标父目录下，源和目标天然同卷；不得改成跨卷复制后删除。
- 每个执行报告必须记录“原始绝对路径 -> 实际隔离绝对路径”的映射。

### 3.2 执行

1. 展示并确认本批目标、统计、隔离路径和“不会释放空间”。
2. 确认隔离根、批次目录和最终目标均不经过 reparse point，最终目标不存在。
3. 创建唯一批次目录；只使用 `Move-Item -LiteralPath` 把精确源路径移动到精确隔离路径。
4. 每移动一项，验证原路径不存在、隔离路径存在，且类型和统计与计划一致。
5. 任一项失败时立即停止；不得改用回收站 API、`Remove-Item`、跨卷复制后删除或其他永久删除方式。

普通清理完成时，非空批次目录和 `.deletion-quarantine` 必须保留，因为它们就是恢复点。这不是磁盘空间清理。

### 3.3 恢复

1. 展示原始路径、隔离路径和恢复清单，等待明确确认。
2. 原始路径已被占用、隔离内容有漂移或任一父路径经过 reparse point 时停止，不覆盖。
3. 只使用 `Move-Item -LiteralPath` 将精确隔离路径移回精确原始路径，并验证结果。
4. 完成后按第 6 节清理空包装目录。

## 4. 模式 B：自动移到当前桌面用户回收站

进入本模式后，在扫描、统计真实目标或创建 fixture 前，必须先做低成本、只读的环境能力预检：确认当前运行于 Windows 交互会话，并且当前执行身份的 SID 与同一 Session 中的 Explorer 所有者一致。若不存在 Explorer、Session 不一致、身份不一致或身份无法验证，立即停止，不扫描真实目标、不创建 fixture，也不移动任何文件。

helper 返回 `EXPLORER_NOT_FOUND`、`SESSION_MISMATCH`、`IDENTITY_MISMATCH` 或 `IDENTITY_UNVERIFIABLE` 时，Agent 必须保留并报告原始错误码，同时向用户统一说明“当前 Agent 运行环境不支持自动回收站”。此时只提供两种默认后续选择：由用户在资源管理器中手动移入回收站，或由用户明确选择模式 A 隔离；不得自动切换模式。模式 C 只能在用户另行明确提出永久删除、看过模式 C 的精确清单并再次确认后使用。

上述预检只用于尽早拒绝明显不支持的环境，不能替代 helper 在真实执行前的全部身份、Session、卷策略、容量、reparse、授权快照和回收证据检查。

### 4.1 唯一允许的执行入口

- 只允许调用与本策略文件位于同一目录的 `Recycle-Bin-Only.ps1`；helper SHA-256 必须为 `AF7E87EC8E5B6160E85A2E8EB069DF23D6A91B6BE81E8B434F36FCF516867128`。
- helper 的目标和 `ProtectedRoot` 只接受完整本地盘符绝对路径，非空 `ProtectedRoot` 必须存在。盘符相对路径（如 `E:cache`）、根相对路径（如 `\cache`）、当前目录相对路径、UNC、设备路径、环境变量和通配符必须在操作前拒绝；现有路径必须逐级解析为真实长名称后再做保护范围比较，不能用 8.3 短名称绕过保护。
- helper 缺失、不是普通文件、任一祖先经过 reparse point、严格 UTF-8 解码失败、存在额外数据流或哈希不匹配时，本模式不可用；不得临时生成替代脚本、复制示例代码、调用 Explorer、Shell verb、第三方工具或永久删除命令。
- helper 只能使用 Microsoft 官方 `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile/DeleteDirectory` 的 `RecycleOption.SendToRecycleBin` 重载。禁止 `DeletePermanently`、`Remove-Item`、`File.Delete`、`Directory.Delete`、`SHFileOperation`、`Shift+Delete` 或任何永久删除回退。
- PowerShell 7 是首选运行时。helper 兼容 Windows PowerShell 5.1 语法，但不得通过 `-ExecutionPolicy Bypass`、修改执行策略、Profile、注册表或其他安全设置强行运行。

### 4.2 确认前清单

执行前展示并确认：

- 每个规范化绝对路径、类型、完整文件数、包含目标根的完整目录数、总字节数；
- 工作区根和项目根等 `ProtectedRoot`；
- 目标及后代是否包含 reparse point；
- 当前模式为“自动回收站”、仍占用原卷空间、不会清空回收站；
- 当前用户/SID/Session/卷组合是否已通过相同 helper 哈希的一次性兼容性测试。未测试时，把同卷唯一小型 fixture 测试写入本次计划；该 fixture 与目标共用这一次确认，不再单独询问。
- 目标卷配置的回收站总容量、当前已用字节数和剩余字节数；若目标不能在不超过剩余容量的前提下放入回收站，则本模式不可用，不得冒险淘汰现有回收项目。

### 4.3 执行与证据

1. 写入或执行 fixture 前重新核对目标快照；有漂移就停止并重新确认。
2. 解析一个具体 PowerShell 可执行文件，不依赖 Profile、alias 或 PATH。优先 PowerShell 7；仅在有效策略允许时使用 Windows PowerShell 5.1。
3. 使用独立子进程和参数数组传入一个精确目标、`ExpectedType`、`ExpectedFileCount`、`ExpectedDirectoryCount`、`ExpectedBytes` 及全部 `ProtectedRoot`；一次调用只处理一个顶层目标。
4. 同时异步捕获 stdout/stderr，等待真实退出码。禁止在当前 PowerShell 进程中直接调用 helper 后从管道推断结果。
5. helper 必须在操作前验证：Windows 交互会话、当前身份 SID、同 Session Explorer 所有者、固定本地卷、卷级回收站策略、`NukeOnDelete=0`、配置总容量、由 `SHQueryRecycleBinW` 返回的当前占用、剩余容量、目标/祖先/后代 reparse 状态、受保护根和授权快照。当前占用无法查询或目标大于剩余容量时必须停止。
6. helper 先记录当前 SID 在目标卷上的 `$I` 元数据集合，再请求 `SendToRecycleBin`；完成后要求原路径不存在，并且出现一个新元数据记录，其原始路径、删除时间及文件大小（文件目标）与本次目标匹配。
7. 只有退出码为 0、stderr 为空、JSON `Status=RECYCLED_VERIFIED` 且原路径不存在时才报告成功。`VALIDATED` 只表示预检通过，没有执行回收。
8. `FAILED` 时停止该目标，不得换工具；正常情况下原路径应保留。`SAFETY_INCIDENT` 表示原路径已消失但恢复证据不完整，立即停止后续删除和无关大量写入，不得报告成功。
9. 执行身份与 Explorer 用户/SID/Session 不一致，或无法读取当前 SID 的回收站证据时，必须在操作前拒绝。不得检查、修改或声称代表其他 SID 的回收站。

### 4.4 兼容性和空间边界

- 本模式是 Windows 通用能力，不写死用户名、盘符、SID、Explorer PID、Codex/Claude 路径或本机卷 GUID；每次运行从真实环境解析并交叉检查。
- 网络路径、设备路径、非固定卷、无交互 Explorer 的服务器/服务会话、回收站策略缺失或无法验证的系统不支持本模式；停止并明确报告未处理任何目标，优先让用户手动使用资源管理器，或询问用户是否明确改用模式 A。不得主动建议或自动切换模式 C。
- 在新电脑、新 SID、新目标卷或 helper 哈希变化后，先对同卷唯一 fixture 执行完整回收测试；fixture 失败时不得处理真实目标。
- 放入回收站不会释放原卷空间。清空回收站属于新的永久删除任务，必须按模式 C 展示完整清单并重新确认；helper 不提供清空能力。

## 5. 模式 C：真正清理空间或永久删除

### 5.1 一次确认前必须展示

- 每个规范化绝对路径及其文件/目录类型；
- 完整文件数、目录数和总字节数；
- 目录包含的范围，以及是否存在链接、挂载点、Git 本地内容或受保护内容；
- 明确文字：“本操作不进入回收站，无法由 Agent 恢复”；
- 将要使用的永久删除方式，以及预计可释放空间。

用户必须在看到上述清单后，对这一批路径明确确认永久删除。一次确认只覆盖当前清单和当前快照，不覆盖后续扫描结果或扩大的范围。

### 5.2 永久删除执行约束

- 执行前重新核对路径、类型、数量和大小；有漂移就停止并重新确认。
- 永久删除调用中只能出现用户已确认的规范化绝对路径字面量。
- 禁止把变量、数组、环境变量、通配符、管道输出、搜索结果、命令替换或动态拼接值传给永久删除命令。
- PowerShell 必须使用完整命令名和 `-LiteralPath`；禁止 `-Path`、别名和 `-Force`。
- 单个文件使用一个精确的 `Remove-Item -LiteralPath '<绝对文件路径>'` 调用。
- 非空目录只有在目录本身及其完整后代范围已展示并确认、且确认无 reparse point 后，才可对该精确目录使用 `-Recurse`；不得把递归范围扩大到其父目录或相邻目录。
- 只读清单可以由搜索生成，但真正的永久删除调用不得直接消费搜索结果。
- 删除失败时停止并报告，不追加 `-Force`，不提权，不改 ACL，也不换用 `cmd /c del`、`rd` 或其他绕过方式。

### 5.3 删除后验证

- 对每个已确认路径验证是否不存在；仍存在的目标列为失败，不重复扩大处理。
- 按成功删除的原始字节数报告预计释放量，并注明文件系统、压缩、稀疏文件等因素可能使实际可用空间变化不同。
- 明确区分成功、失败和跳过的路径，不得只说“清理完成”。

## 6. 隔离目录的无残留收尾

隔离内容被全部恢复，或已经按模式 C 明确确认并永久删除后，必须收掉空包装目录：

1. 使用包含隐藏项的只读枚举确认批次目录完全为空。
2. 批次目录为空时，只对该批次目录执行非递归、无 `-Force` 的精确 `-LiteralPath` 删除；随后验证它不存在。
3. 再用包含隐藏项的只读枚举确认父级 `.deletion-quarantine` 是否完全为空。
4. 隔离根为空时，只对该隔离根执行非递归、无 `-Force` 的精确 `-LiteralPath` 删除；随后验证它不存在。
5. 任一目录仍含其他文件、子目录、隐藏项或未知内容时，保留它并报告；禁止递归清除。

因此，某批隔离内容处理完后不会留下空的 `<batch-id>`。当最后一批也处理完时，不会留下空的 `.deletion-quarantine`；仍有其他隔离内容时则必须保留。

## 7. 误删和最终报告

发现或怀疑误删后，立即停止后续删除和无关的大量磁盘写入。优先从本批隔离路径恢复；回收站模式由用户在当前桌面回收站恢复；其次检查备份、版本控制和文件历史。无法恢复时如实报告。

每次操作后报告：

- 用户选择的模式；
- 成功、失败和跳过的精确路径；
- 文件数、目录数和总字节数；
- 是否可恢复及实际恢复位置；
- 是否真正释放空间及预计释放量；
- 空批次目录和空隔离根是否已收尾；
- 任何状态漂移、残留或无法验证的事项。
- 模式 B 还须报告 helper SHA-256、真实运行时、退出码、stdout/stderr、执行身份/SID/Session、卷 ID、fixture 结果和回收站证据状态；不得输出其他回收站项目内容。
- 模式 B 因环境能力预检或上述四个身份/Session 错误码而未执行时，还须报告原始错误码、统一的不支持说明，以及“没有移动任何文件”；不得把预检失败报告成 helper 或目标文件故障。

## 8. 官方依据和 helper 完整性

- Microsoft `FileSystem.DeleteFile`：<https://learn.microsoft.com/en-us/dotnet/api/microsoft.visualbasic.fileio.filesystem.deletefile>
- Microsoft `FileSystem.DeleteDirectory`：<https://learn.microsoft.com/en-us/dotnet/api/microsoft.visualbasic.fileio.filesystem.deletedirectory>
- Microsoft `RecycleOption`：<https://learn.microsoft.com/en-us/dotnet/api/microsoft.visualbasic.fileio.recycleoption>
- Microsoft `SHQueryRecycleBinW`：<https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shqueryrecyclebinw>
- Microsoft `SHQUERYRBINFO`：<https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-shqueryrbinfo>

官方 API 将 `DeletePermanently` 和 `SendToRecycleBin` 定义为不同枚举值，并说明 UI/recycle 参数只适用于交互式应用。`SHQueryRecycleBinW` 返回指定卷回收站的大小，`SHQUERYRBINFO.i64Size` 是其中全部对象的总字节数。helper 用它验证剩余容量，并固定使用 `SendToRecycleBin`、`OnlyErrorDialogs` 和 `ThrowException`；不包含永久删除分支。
