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
