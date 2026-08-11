# File Deletion Safety Rules

**English** | [简体中文](README.zh-CN.md)

A portable Windows safety policy package for file deletion operations performed by Codex, Claude, and OpenCode.

The package defines three explicit modes:

- Ordinary "delete / clean / remove" requests move confirmed targets to a same-volume quarantine. This is recoverable but does not free disk space.
- "Move to Recycle Bin" is available only in a real interactive Windows user session where the current identity matches Explorer in the same session and all Recycle Bin evidence can be verified. A metadata fingerprint binds relative paths, types, file lengths, and file last-write timestamps so same-size replacements and renames are detected between validation and execution.
- "Permanently delete / clean up disk space" requires an exact target list and a separate confirmation. It bypasses the Recycle Bin and cannot be restored by the Agent.

## Cleanup confirmation

The fixed ten-row, two-column Markdown table used for every cleanup confirmation is shown below. A confirmation request renders this table directly; it must not use a code fence, a colon-list substitute, or added or removed rows.

| Item | Content |
|---|---|
| Cleanup item | A purpose-based name for the selected objects |
| Location | Normalized top-level absolute paths; a non-file object uses an accurately identifiable location or identifier |
| Scope | Counts of top-level files, complete directories, Junction entries, or other top-level objects |
| Contents | Ordinary file and directory counts, or verified domain facts for non-file objects |
| Disk usage | Exact bytes and a readable unit, or an explicit statement that no meaningful space is freed |
| Reason | Evidence supporting this cleanup decision |
| Method | Mode, exact action, recoverability, and disk-space effect |
| Safety boundary | Links, local Git state, protected content, and preserved objects |
| Cleanup result | Expected state after execution |
| Recovery method | An available restoration or recreation method; otherwise `none` |

Small, medium, and large operations keep this structure. A large operation is split by local volume and cleanup mode rather than hiding targets behind a second document. The confirmation prompt follows the table and is not a card row.

Only normalized top-level absolute target paths are listed; descendant files and directories are summarized by count and size. The Agent does not create a per-cleanup local manifest or replace useful details with an opaque snapshot ID. If a context transition loses the confirmed snapshot, the Agent must scan again and show a new card for confirmation.

A non-file object such as a Git branch uses the same table when this policy applies. Each cell contains the verified facts relevant to that object without imposing a second fixed set of subfields. The recovery method may describe restoration from quarantine, the Recycle Bin, or a backup, or recreation from verified Git or build inputs; it is `none` when no method is available.

Every Junction is resolved before confirmation. If its real target is also selected for cleanup and lies outside every listed top-level directory, that target appears as its own top-level path. A target already covered by a listed top-level directory is summarized once instead of being duplicated. Shared targets remain unchanged when only their Junction entries are removed. An unknown-purpose Junction stops the operation before a confirmable card is shown. Because the Recycle Bin helper rejects all reparse points in or above a target tree, Mode B is unavailable for any Junction-bearing target; Junction handling is limited to a boundary-proven Mode A or Mode C operation.

## Important compatibility boundary

Automatic Recycle Bin support depends on the runtime environment. It fails closed in Agent sandboxes, service sessions, sessions without a matching Explorer process, identity mismatches, network paths, and systems whose Recycle Bin policy cannot be verified. This is not an installation failure and never falls back to permanent deletion.

This package does not install a desktop bridge, persistent service, scheduled task, administrator elevation mechanism, network listener, or permanent-delete fallback.

## Prerequisites

- Windows with installation targets on a local fixed volume.
- PowerShell 7 (`pwsh`) for installation, verification, uninstallation, and the package test suite.

The Recycle Bin helper is also kept syntactically compatible with Windows PowerShell 5.1 for constrained legacy environments, but the release test only parser-checks 5.1. Do not treat that parser check as full 5.1 runtime support for the package scripts.

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
tests/Test-Package.ps1                 Static and isolated behavior validation
manifest.json                          Installation manifest
```

## Get the package

```powershell
git clone https://github.com/SssoGin/file-deletion-safety-rules.git
Set-Location .\file-deletion-safety-rules
```

You can also download the source ZIP from GitHub, extract it, and ask your Agent to run the installation preview first.

## Ask an Agent to install it

Run Preview first and retain its `PlanSha256`. Apply accepts only the exact plan that was reviewed:

```powershell
$preview = (& pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All | Out-String) | ConvertFrom-Json
$preview | ConvertTo-Json -Depth 14
```

Review the target files, shared policy location, complete managed block, and `PlanSha256`. After explicit confirmation, pass that same hash to Apply:

```powershell
pwsh -NoProfile -File .\scripts\Install-FileDeletionSafetyRules.ps1 -Mode Apply -Tool All -ExpectedPlanSha256 $preview.PlanSha256
pwsh -NoProfile -File .\scripts\Verify-FileDeletionSafetyRules.ps1 -Tool All
```

Replace `All` with `Codex`, `Claude`, or `OpenCode` when installing for one tool only. The installer resolves paths from the current user profile and does not contain the publisher's username or drive paths.

If any planned file changes between Preview and Apply, Apply returns `PLAN_MISMATCH` before writing. A multi-file failure triggers reverse-order rollback. Existing files are preserved in a transaction directory under `.file-deletion-safety-rules-backups`, and files created by a failed transaction are moved there rather than permanently deleted.

The installer, uninstaller, and verifier reject any existing reparse point, including a symbolic link or junction, between the selected profile root and a package-managed path. They do not follow a profile child path into another location.

Successful installation writes `.agents/file-deletion-safety-rules.install.json`. This receipt binds the package version, policy and helper hashes, and installed tool set. The verifier reconstructs the expected receipt and managed blocks from the current package and requires exact matches.

On reinstall or upgrade, the shared policy, helper, and receipt must normally be either all absent or all present. When present, the installer parses the receipt strictly, requires its policy/helper hashes to match the files on disk, and requires its tool set to match exact current managed blocks. The only receiptless exception is the exact v1.0.0 layout declared in `manifest.json`: both shared files must match the declared v1.0.0 hashes, and ownership must be proven by at least one exact package-managed block or the exact supported unmanaged `0.1` adapter. Every detected supported unmanaged adapter must be selected for migration; it is replaced by one managed block while adjacent content is preserved. The installer then plans the policy/helper update and creates the first receipt transactionally. Any other partial installation, malformed receipt, modified shared file, modified managed block, unknown receiptless pair, or unowned block stops in Preview.

## Existing unmanaged rules

The installer owns only blocks enclosed by this package's managed markers. Except for the exact receiptless v1.0.0 migration described above, if a selected tool config contains an unsupported unmanaged deletion-safety heading listed in `manifest.json`—including legacy `0.1` headings or an unmarked copy of the current adapter heading—Preview fails before any write. Headings inside one exact managed block are excluded from this unmanaged scan. The installer does not interpret or alter unknown unmanaged content, and it never appends a managed block beside it.

Back up and manually reconcile any unmanaged policy before running Preview again. Incomplete or duplicated managed markers, or managed and unsupported unmanaged rules in the same config, also fail closed because ownership is ambiguous.

## Uninstall

Preview by default and retain the uninstall plan hash:

```powershell
$uninstallPreview = (& pwsh -NoProfile -File .\scripts\Uninstall-FileDeletionSafetyRules.ps1 -Mode Preview -Tool All | Out-String) | ConvertFrom-Json
$uninstallPreview | ConvertTo-Json -Depth 14
```

After explicit confirmation, apply that exact snapshot:

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-FileDeletionSafetyRules.ps1 -Mode Apply -Tool All -ExpectedPlanSha256 $uninstallPreview.PlanSha256
```

The default uninstall removes only this package's exact managed block. Add `-RemoveSharedFiles` to both Preview and Apply only when the shared policy, helper, and receipt should also be removed. Shared files are eligible only when no managed blocks remain and manifest, receipt, and current file hashes prove package ownership. Removed files are moved to the reported transaction backup, not permanently deleted. User-modified or ambiguously owned files stop the uninstall.

## Package verification and release identity

Run the non-production package suite with:

```powershell
pwsh -NoProfile -File .\tests\Test-Package.ps1
```

It validates all runtime hashes, parses every package script with PowerShell 7 and Windows PowerShell 5.1, and runs isolated helper, installer, uninstaller, and verifier fixtures under `.test-profile`. It does not use the real Recycle Bin or permanently delete fixtures.

`manifest.json` detects changes to the eight runtime files and proves that they agree with this manifest, but that internal hash agreement does not prove release provenance because a modified archive could replace both a file and its recorded hash. For source identity, obtain the package from this repository and pin or compare the Git commit or release tag separately.

## When automatic Recycle Bin mode is unavailable

`EXPLORER_NOT_FOUND`, `SESSION_MISMATCH`, `IDENTITY_MISMATCH`, and `IDENTITY_UNVERIFIABLE` mean that the current Agent environment cannot safely automate the Recycle Bin. The Agent must preserve the raw error code, state that no files were moved, and let the user either use File Explorer manually or explicitly choose quarantine mode.

## Releases

See [GitHub Releases](https://github.com/SssoGin/file-deletion-safety-rules/releases) for versions and release notes.

## License

This project is licensed under the MIT License. See `LICENSE`.
