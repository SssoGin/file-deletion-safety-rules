# v1.2.1 — Antigravity Support

## English

- Add Antigravity as a fifth first-class installation target. `-Tool Antigravity` manages its global `~/.gemini/GEMINI.md`; `-Tool All` now covers all five supported tools.
- Extend the manifest, installer, uninstaller, verifier and ownership receipt consistently. Existing 1.2.0 four-tool installations can add Antigravity through the reviewed Preview/Apply transaction.
- Preserve existing Antigravity rules, encoding and newline style. Keep unrelated global rules, settings, accounts and credentials untouched; reject modified blocks, receipt drift and linked profile paths.
- Pin ten runtime files and add eight isolated Antigravity behavior cases covering installation, idempotence, upgrade, tamper detection, shared-file protection and safe uninstall.
- Keep the complete deletion policy and Recycle Bin helper unchanged. No real Recycle Bin operation or permanent deletion is needed for the package tests.
- Document the official shared rule location, the possible Gemini CLI overlap, and the difference between verified installation and model behavior. Templates contain profile-relative paths; private configurations, receipts, backups and test evidence are not distributed.

Helper SHA-256: `70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`.

Run Preview, review the exact plan, Apply with the same `PlanSha256`, and verify. Open a new Antigravity conversation to load the rule. Recycle Bin support still depends on the host identity, session, volume policy and recovery evidence; no permission bypass or permanent-delete fallback is added.

## 简体中文

- 新增 Antigravity 作为第五个正式安装目标；`-Tool Antigravity` 管理其全局 `~/.gemini/GEMINI.md`，`-Tool All` 现覆盖全部五端。
- manifest、安装器、卸载器、验证器及所有权回执同步适配；已有 1.2.0 四端安装可通过审阅后的 Preview/Apply 事务加入 Antigravity。
- 保留 Antigravity 已有规则、编码和换行风格；不修改其他全局规则、设置、账号或凭据，拒绝被修改的规则块、回执漂移和链接路径。
- 固定 10 个运行时文件哈希，新增 8 个隔离行为用例，覆盖安装、幂等、升级、篡改识别、共享文件保护及安全卸载。
- 完整删除策略和回收站 helper 保持不变；包测试不需要操作真实回收站或永久删除文件。
- 补充官方通用入口、可能影响 Gemini CLI 的边界，以及安装验证与模型行为的区别；模板只保存相对用户目录的路径，不分发私有配置、安装回执、备份和测试证据。

Helper SHA-256：`70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`。

先运行 Preview、审阅精确计划，再以同一 `PlanSha256` 执行 Apply 并验证。Antigravity 新开会话后加载规则；回收站能力仍受身份、Session、卷策略及恢复证据约束，不增加权限绕过或永久删除回退。

---

# v1.2.0 — DeepSeek Harness Support

## English

- Add DeepSeek Harness as a fourth first-class installation target. Its global instruction file `~/.dsh/AGENTS.md` receives the same managed rule block and shared policy as Codex, Claude and OpenCode.
- Extend the manifest, installer, uninstaller and verifier to four tools. `All` now covers Codex, Claude, OpenCode and DeepSeekHarness, and the ownership receipt and exact verification include the new target.
- Keep the complete policy and the Recycle Bin helper unchanged; the helper SHA-256 remains `70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`.
- Update the package documentation and tests for the new target. The manifest now pins nine runtime files.
- Existing installations upgrade through the normal Preview/Apply path: the installer writes the DeepSeek Harness managed block and updates the receipt tool set transactionally.

Helper SHA-256: `70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`.

For an existing installation, run Preview, inspect the exact plan, then Apply with that `PlanSha256` and verify. A user-modified or older incompatible managed block must be reconciled explicitly; the installer does not overwrite it automatically.

## 简体中文

- 新增 DeepSeek Harness 作为第四个正式安装目标；其全局指令文件 `~/.dsh/AGENTS.md` 使用与 Codex、Claude、OpenCode 相同的 managed block 和共享策略。
- manifest、安装器、卸载器和验证器同步支持四个工具；`All` 现覆盖 Codex、Claude、OpenCode 和 DeepSeekHarness，安装回执与精确验证包含新目标。
- 完整策略与回收站 helper 保持不变；helper SHA-256 仍为 `70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`。
- 更新包文档与测试；manifest 现固定 9 个运行时文件的哈希。
- 已有安装按常规 Preview/Apply 路径升级：安装器以事务方式写入 DeepSeek Harness managed block 并更新 receipt 工具集合。

Helper SHA-256：`70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`。

已有安装先运行 Preview，审阅精确计划后用同一 `PlanSha256` 执行 Apply 并验证。用户修改过或与新包不兼容的旧 managed block 须明确协调，安装器不会自动覆盖。

---

# v1.1.0 — Recycle Bin Defaults and Authorization Reuse

## English

- Default ordinary delete, clean and remove requests to the Recycle Bin. Same-volume quarantine now requires an explicit request. Unsupported Recycle Bin environments still stop without changing mode or falling back to permanent deletion.
- Reuse verified authorization covering exact targets, actions and recovery methods. Showing the fixed ten-row cleanup table does not create an extra approval step when that scope is already authorized.
- Support a narrowly limited temporary-file exception only under explicit user authorization. Installing the package does not grant it; non-empty directories, user data, project code, deliverables, credentials and recovery materials remain excluded.
- Allow optional recovery snapshots in authorized task records. Resume only when the authorization source, scope and current state can be verified; snapshots never grant permission themselves.
- Clarify instruction precedence and routine recoverable editing, and keep detailed execution evidence while presenting concise user-facing outcomes.
- Publish the same portable policy and adapters for Codex, Claude and OpenCode. Runtime paths are resolved during installation; no personal profile paths, private configuration or installation receipts are included.
- Update version checks and static policy contracts for this release. Limit Windows PowerShell 5.1 parsing to the package scripts, avoiding traversal of generated test fixtures. The Recycle Bin helper and its execution safeguards are unchanged.

Helper SHA-256: `70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`.

For an existing installation, run Preview, inspect the exact plan, then Apply with that `PlanSha256` and verify. A user-modified or older incompatible managed block must be reconciled explicitly; the installer does not overwrite it automatically.

## 简体中文

- 普通“删除、清理、移除”默认送入回收站；同卷隔离须明确请求。回收站环境不受支持时仍停止，不自动切换模式或改用永久删除。
- 复用已核实且覆盖精确目标、动作和恢复方式的授权；范围已有授权时，展示固定十行清理表不再额外产生审批步骤。
- 有限临时文件例外须由用户明确授权，安装本包不会自动授予；非空目录、用户资料、项目代码、交付物、凭据及恢复材料均被排除。
- 可在已授权任务记录中按需保存恢复快照；只有授权来源、范围与现状均可核对时才继续，快照本身不产生权限。
- 明确指令优先级和可恢复常规编辑的边界；保留详细执行证据，面向用户简明报告结果。
- Codex、Claude 和 OpenCode 共用可移植策略及入口；安装时动态解析路径，包内不包含个人用户目录、私有配置或安装回执。
- 更新本次发布的版本检查和策略静态契约；Windows PowerShell 5.1 仅解析包内脚本，不遍历生成的测试目录。回收站 helper 及其执行保护保持不变。

Helper SHA-256：`70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A`。

已有安装先运行 Preview，审阅精确计划后用同一 `PlanSha256` 执行 Apply 并验证。用户修改过或与新包不兼容的旧 managed block 须明确协调，安装器不会自动覆盖。

---

# v1.0.1 — Security Hardening

## English

- Require a newly created, matching Recycle Bin `$I` metadata and `$R` data pair before reporting `RECYCLED_VERIFIED`.
- Verify the `$R` object type, complete file and directory counts, byte count, and deterministic metadata fingerprint against the authorized snapshot.
- Treat an unsafe or unreadable post-operation `$R` snapshot as missing evidence so a vanished source is reported as `SAFETY_INCIDENT`, not an ordinary preflight failure.
- Bind relative paths, types, file lengths, and file last-write timestamps into a metadata fingerprint, require the confirmed fingerprint for execution, and recheck the complete authorized snapshot immediately before calling the Recycle Bin API.
- Bind install and uninstall Apply operations to the exact reviewed Preview through `PlanSha256` and `-ExpectedPlanSha256`; state drift fails before writes.
- Apply multi-file changes transactionally with reverse-order rollback and timestamped backups. Uninstall moves shared files into backup instead of permanently deleting them.
- Reject symbolic links, junctions, and other reparse points anywhere between the selected profile root and package-managed paths; include the current operation in rollback coverage before mutation.
- Record installation ownership in `.agents/file-deletion-safety-rules.install.json`, and verify package files, installed files, managed blocks, and the reconstructed receipt exactly.
- Support the exact receiptless v1.0.0 upgrade layout only when the declared policy/helper hashes and at least one exact managed block or exact supported unmanaged `0.1` adapter prove ownership; migrate every detected supported unmanaged adapter to one managed block.
- Reject all other known unsupported unmanaged deletion-safety headings configured in the manifest before writing, including modified legacy `0.1` forms and an unmarked current adapter heading, while excluding the heading inside an exact managed block.
- Preserve the original UTF-8 BOM state and LF/CRLF newline style when installing, updating, or uninstalling managed blocks.
- Publish a schema 2 manifest with version `1.0.1` and hashes for all eight runtime files.
- Standardize every deletion preview on one fixed ten-row, two-column Markdown cleanup-confirmation table, including a recovery-method row. Render the table directly, keep descendant details aggregated, apply it to Git refs and other non-file objects, avoid per-cleanup manifest files, fail closed on unknown Junction purposes, and make the Recycle Bin helper's no-reparse boundary explicit.
- Add 48 isolated behavior cases covering Recycle Bin evidence and metadata drift, strict ownership-receipt enforcement, receiptless v1.0.0 migration (including the exact supported unmanaged `0.1` adapter), unmanaged-heading variants, complete-manifest rejection, generic version/tool expansion, install transactions and rollback, nested junction rejection, safe uninstall, encoding preservation, and tamper detection, plus static cleanup-card contract checks and PowerShell 7 / Windows PowerShell 5.1 parsing.

The runtime hashes prove consistency with the included manifest. They do not independently prove the archive's Git commit, tag, or release provenance.

The helper SHA-256 for this release is:

```text
70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A
```

## 简体中文

- 只有本次新增且匹配的回收站 `$I` 元数据和 `$R` 数据对象同时存在时，才允许报告 `RECYCLED_VERIFIED`。
- `$R` 对象的类型、完整文件数、完整目录数、总字节数和确定性元数据指纹必须与授权快照一致。
- 事后 `$R` 快照不安全或不可读时按证据缺失处理，源已消失时必须报告 `SAFETY_INCIDENT`，不能降级成普通预检失败。
- 把相对路径、类型，以及文件长度和文件最后写入时间绑定为元数据指纹，真正执行时必须提供已确认指纹，并在调用回收站 API 前立即重新检查完整授权快照。
- 安装和卸载的 Apply 必须通过 `PlanSha256` 与 `-ExpectedPlanSha256` 绑定到用户看过的 Preview；状态漂移时在写入前停止。
- 多文件修改使用事务、反向回滚和时间戳备份；卸载共享文件时只移动到备份，不做永久删除。
- 拒绝所选 profile 根与包管理路径之间任何 symbolic link、junction 或其他 reparse point；在变更前把当前动作纳入回滚覆盖。
- 使用 `.agents/file-deletion-safety-rules.install.json` 记录安装所有权，并精确验证包内文件、已安装文件、managed block 和重建后的 receipt。
- 只有 manifest 声明的 v1.0.0 policy/helper 哈希和至少一个精确 managed block 或受支持的精确未托管 `0.1` adapter 同时证明所有权时，才支持无 receipt v1.0.0 升级；检测到的受支持未托管 adapter 必须全部迁移成单个 managed block。
- 对其他已知未托管删除安全规则标题在写入前直接拒绝，包括被修改过的旧 `0.1` 形式和无 marker 的当前 adapter 标题；精确 managed block 内的标题不计为未托管内容。
- 安装、更新或卸载 managed block 时保留原文件的 UTF-8 BOM 状态和 LF/CRLF 换行风格。
- manifest 升级为 schema 2，写入版本 `1.0.1` 和全部 8 个运行时文件哈希。
- 所有删除预览统一使用固定十行、两列 Markdown 清理确认表格，并加入“恢复方式”固定行；表格必须直接渲染，后代内容只做汇总，Git ref 等非文件对象也不能退回冒号列表，不生成每次清理专用清单，在 Junction 用途不明时安全停止，并明确回收站 helper 不接受 reparse point。
- 新增 48 个隔离行为用例，覆盖回收证据与元数据漂移、严格安装 receipt 所有权门禁、真实无 receipt v1.0.0 迁移（含受支持的精确未托管 `0.1` adapter）、未托管标题变体、残缺 manifest 拒绝、通用版本/工具扩展、安装事务与回滚、嵌套 junction 拒绝、安全卸载、编码保留和篡改识别；另做确认卡静态契约检查，并同时检查 PowerShell 7 与 Windows PowerShell 5.1 解析。

运行时哈希只能证明与包内 manifest 一致，不能单独证明压缩包对应的 Git commit、tag 或 Release 来源。

本次发布的 helper SHA-256：

```text
70A676487C3F08480EB4891D09CD85802FD81B06A1B80621D7720B24EAB9212A
```

# v1.0.0 — Initial Release

[English](#english) | [简体中文](#简体中文)

## English

### Highlights

- Portable Windows file deletion safety rules for Codex, Claude, and OpenCode.
- One shared policy and a hash-pinned Recycle Bin helper.
- Preview-first installers with managed blocks, timestamped backups, and verification.
- No desktop bridge, persistent service, scheduled task, administrator elevation mechanism, network listener, or permanent-delete fallback.

### Three explicit safety modes

1. **Quarantine:** ordinary delete, clean, or remove requests move confirmed targets to a same-volume quarantine and remain recoverable.
2. **Recycle Bin:** runs only when the current identity, Windows session, Explorer owner, volume policy, capacity, target snapshot, and Recycle Bin evidence can all be verified.
3. **Permanent deletion:** requires an exact list and separate confirmation, bypasses the Recycle Bin, and cannot be restored by the Agent.

### Session switch

- Every new chat or session defaults to `ON`.
- `Disable file deletion safety rules` affects only the current session and does not persist or propagate to other Agents.
- `Enable file deletion safety rules` restores the complete policy.
- `Query file deletion safety rules status` reports the state without changing it.
- System, platform, permission, project, and other user rules remain effective while this package is `OFF`.

### Compatibility boundary

Automatic Recycle Bin mode fails closed in sandboxes, service sessions, identity or session mismatches, network paths, and environments where Recycle Bin policy or evidence cannot be verified. It does not silently change to permanent deletion.

### Installation

Download the GitHub source archive or clone the repository, run `Install-FileDeletionSafetyRules.ps1` in `Preview` mode, review the complete plan, explicitly approve it, apply it, and run `Verify-FileDeletionSafetyRules.ps1`.

The helper SHA-256 for this release is:

```text
AF7E87EC8E5B6160E85A2E8EB069DF23D6A91B6BE81E8B434F36FCF516867128
```

No standalone binaries are attached. GitHub provides source archives for the tagged commit.

## 简体中文

### 主要内容

- 面向 Windows 上 Codex、Claude 和 OpenCode 的可移植文件安全删除规则。
- 三端共用一份完整策略和一个固定哈希的回收站 helper。
- 安装器默认预览，使用 managed block、时间戳备份和安装后验证。
- 不包含桌面桥接、常驻服务、计划任务、管理员提权、网络监听或永久删除回退。

### 三种明确模式

1. **隔离：**普通“删除、清理、移除”把已确认目标移动到同卷隔离目录，可恢复但不释放空间。
2. **回收站：**只有当前身份、Windows Session、Explorer 所有者、卷策略、容量、目标快照和回收证据均可验证时才执行。
3. **永久删除：**必须展示精确清单并单独确认，不进入回收站，无法由 Agent 恢复。

### 会话开关

- 每个新聊天或会话默认是 `ON`。
- `关闭文件安全删除规则` 只影响当前会话，不持久化，也不传播到其他 Agent。
- `启用文件安全删除规则` 恢复完整策略。
- `查询文件安全删除规则状态` 只报告状态，不进行切换。
- 即使本规则为 `OFF`，系统、平台、权限、项目和其他用户规则仍然有效。

### 兼容性边界

自动回收站模式在沙箱、服务会话、身份或 Session 不一致、网络路径，以及无法验证回收站策略或证据的环境中安全停止，不会静默切换为永久删除。

### 安装

下载 GitHub 源码包或克隆仓库，先以 `Preview` 模式运行 `Install-FileDeletionSafetyRules.ps1`，检查完整计划并明确确认后再应用，最后运行 `Verify-FileDeletionSafetyRules.ps1`。

本次发布的 helper SHA-256：

```text
AF7E87EC8E5B6160E85A2E8EB069DF23D6A91B6BE81E8B434F36FCF516867128
```

本次不附加独立二进制文件；GitHub 会为对应 Tag 自动提供源码压缩包。
