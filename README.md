# File Deletion Safety Rules

**English** | [简体中文](README.zh-CN.md)

A portable Windows safety policy package for file deletion operations performed by Codex, Claude, and OpenCode.

The package defines three explicit modes:

- Ordinary "delete / clean / remove" requests move confirmed targets to a same-volume quarantine. This is recoverable but does not free disk space.
- "Move to Recycle Bin" is available only in a real interactive Windows user session where the current identity matches Explorer in the same session and all Recycle Bin evidence can be verified.
- "Permanently delete / clean up disk space" requires an exact target list and a separate confirmation. It bypasses the Recycle Bin and cannot be restored by the Agent.

## Important compatibility boundary

Automatic Recycle Bin support depends on the runtime environment. It fails closed in Agent sandboxes, service sessions, sessions without a matching Explorer process, identity mismatches, network paths, and systems whose Recycle Bin policy cannot be verified. This is not an installation failure and never falls back to permanent deletion.

This package does not install a desktop bridge, persistent service, scheduled task, administrator elevation mechanism, network listener, or permanent-delete fallback.

## Session switch

File deletion safety rules default to `ON` in every new chat or session. You can give the Agent these direct commands:

- `Disable file deletion safety rules` or `关闭文件安全删除规则`: switch to `OFF`;
- `Enable file deletion safety rules` or `启用文件安全删除规则`: restore `ON`;
- `Query file deletion safety rules status` or `查询文件安全删除规则状态`: report the current state without changing it.

Clear equivalent wording is also accepted. Questions, quotations, negated statements, or ambiguous wording must not switch the state.

`OFF` applies only to the current chat or session. It is not written to disk and is not shared across Codex, Claude, OpenCode, or other Agents. A new session, a different Agent, or ambiguous restored context defaults back to `ON`. A switch affects only operations that have not started. System, platform, permission, project, and other user rules remain in force.

## Package layout

```text
README.md                              Default English documentation
README.zh-CN.md                        Simplified Chinese documentation
RELEASE_NOTES.md                       Bilingual release notes
policy/file-deletion-safety.md         Complete policy
helpers/Recycle-Bin-Only.ps1           Hash-pinned Recycle Bin helper
adapters/*.md                          Global rule snippets for three tools
scripts/Install-FileDeletionSafetyRules.ps1    Preview / install
scripts/Verify-FileDeletionSafetyRules.ps1     Installation verification
scripts/Uninstall-FileDeletionSafetyRules.ps1  Preview / uninstall
tests/Test-Package.ps1                 Static package validation
manifest.json                          Installation manifest
```

## Get the package

```powershell
git clone https://github.com/SssoGin/file-deletion-safety-rules.git
Set-Location .\file-deletion-safety-rules
```

You can also download the source ZIP from GitHub, extract it, and ask your Agent to run the installation preview first.

## Ask an Agent to install it

Run Preview first. Do not apply changes before reviewing the plan:

```powershell
pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All
```

Review the target files, shared policy location, and complete managed block. After explicit confirmation, run:

```powershell
pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Apply -Tool All
pwsh -NoProfile -File .\scripts\Verify-FileDeletionSafetyRules.ps1 -Tool All
```

Replace `All` with `Codex`, `Claude`, or `OpenCode` when installing for one tool only. The installer resolves paths from the current user profile and does not contain the publisher's username or drive paths.

## Uninstall

Preview by default:

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All
```

Use `-Mode Apply` only after explicit confirmation. The default uninstall removes only this package's managed block. Shared policy and helper files are removed only when `-RemoveSharedFiles` is explicitly supplied and no managed blocks remain in any supported tool configuration.

## When automatic Recycle Bin mode is unavailable

`EXPLORER_NOT_FOUND`, `SESSION_MISMATCH`, `IDENTITY_MISMATCH`, and `IDENTITY_UNVERIFIABLE` mean that the current Agent environment cannot safely automate the Recycle Bin. The Agent must preserve the raw error code, state that no files were moved, and let the user either use File Explorer manually or explicitly choose quarantine mode.

## Releases

See [GitHub Releases](https://github.com/SssoGin/file-deletion-safety-rules/releases) for versions and release notes.

## License

This project is licensed under the MIT License. See `LICENSE`.
