[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-PowerShellFile {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void] $startInfo.ArgumentList.Add('-NoProfile')
    [void] $startInfo.ArgumentList.Add('-File')
    [void] $startInfo.ArgumentList.Add($LiteralPath)
    foreach ($argument in $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        Stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    }
}

function Convert-ResultJson {
    param([Parameter(Mandatory)][psobject] $ProcessResult)

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ProcessResult.Stdout)) -Message "Installer emitted no JSON. stderr: $($ProcessResult.Stderr)"
    return $ProcessResult.Stdout | ConvertFrom-Json -Depth 20
}

function New-TestProfile {
    param([Parameter(Mandatory)][string] $TestRoot)

    $profileRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    return $profileRoot
}

function New-InstalledProfile {
    param(
        [Parameter(Mandatory)][string] $TestRoot,
        [Parameter(Mandatory)][string] $InstallerPath
    )

    $profileRoot = New-TestProfile -TestRoot $TestRoot
    $previewResult = Invoke-PowerShellFile -LiteralPath $InstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $profileRoot)
    $preview = Convert-ResultJson -ProcessResult $previewResult
    Assert-True -Condition ($previewResult.ExitCode -eq 0) -Message 'Ownership fixture Preview failed.'
    $applyResult = Invoke-PowerShellFile -LiteralPath $InstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $profileRoot, '-ExpectedPlanSha256', [string] $preview.PlanSha256)
    $apply = Convert-ResultJson -ProcessResult $applyResult
    Assert-True -Condition ($applyResult.ExitCode -eq 0 -and $apply.Status -eq 'APPLIED') -Message 'Ownership fixture Apply failed.'
    return $profileRoot
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installerPath = Join-Path $packageRoot 'scripts\Install-FileDeletionSafetyRules.ps1'
$testRoot = Join-Path $packageRoot '.test-profile\installer'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
. $installerPath

$successProfile = New-TestProfile -TestRoot $testRoot
$successPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $successProfile)
Assert-True -Condition ($successPreviewResult.ExitCode -eq 0) -Message "Installer Preview failed: $($successPreviewResult.Stderr)"
$successPreview = Convert-ResultJson -ProcessResult $successPreviewResult
Assert-True -Condition ([string] $successPreview.PlanSha256 -match '^[A-F0-9]{64}$') -Message 'RED: Preview did not return a deterministic PlanSha256.'
$successApplyResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $successProfile, '-ExpectedPlanSha256', [string] $successPreview.PlanSha256)
$successApply = Convert-ResultJson -ProcessResult $successApplyResult
Assert-True -Condition ($successApplyResult.ExitCode -eq 0 -and $successApply.Status -eq 'APPLIED') -Message "Bound Apply failed: $($successApplyResult.Stderr)"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $successProfile '.agents\file-deletion-safety.md') -PathType Leaf) -Message 'Installed policy is missing.'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $successProfile '.agents\Recycle-Bin-Only.ps1') -PathType Leaf) -Message 'Installed helper is missing.'
$receiptPath = Join-Path $successProfile '.agents\file-deletion-safety-rules.install.json'
Assert-True -Condition (Test-Path -LiteralPath $receiptPath -PathType Leaf) -Message 'RED: installation receipt is missing.'
$receipt = Get-Content -Raw -LiteralPath $receiptPath -Encoding utf8 | ConvertFrom-Json -Depth 20
Assert-True -Condition ($receipt.PackageVersion -eq '1.0.1') -Message 'Installation receipt version is incorrect.'
Assert-True -Condition (@($receipt.InstalledTools).Count -eq 1 -and $receipt.InstalledTools[0] -eq 'Codex') -Message 'Installation receipt does not record the installed tool.'
$idempotentPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $successProfile)
$idempotentPreview = Convert-ResultJson -ProcessResult $idempotentPreviewResult
Assert-True -Condition (@($idempotentPreview.Plan.Operations | Where-Object { $_.Action -ne 'Unchanged' }).Count -eq 0) -Message 'A repeated installation is not idempotent.'
$idempotentApplyResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $successProfile, '-ExpectedPlanSha256', [string] $idempotentPreview.PlanSha256)
$idempotentApply = Convert-ResultJson -ProcessResult $idempotentApplyResult
Assert-True -Condition ($idempotentApplyResult.ExitCode -eq 0 -and $idempotentApply.Status -eq 'APPLIED' -and $null -eq $idempotentApply.BackupRoot) -Message 'Idempotent Apply performed a transaction or failed.'

$toolExpansionProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$toolExpansionPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Claude', '-UserProfileRoot', $toolExpansionProfile)
$toolExpansionPreview = Convert-ResultJson -ProcessResult $toolExpansionPreviewResult
Assert-True -Condition ($toolExpansionPreviewResult.ExitCode -eq 0) -Message 'A package-owned installation could not add another tool.'
$toolExpansionApplyResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Claude', '-UserProfileRoot', $toolExpansionProfile, '-ExpectedPlanSha256', [string] $toolExpansionPreview.PlanSha256)
$toolExpansionApply = Convert-ResultJson -ProcessResult $toolExpansionApplyResult
$toolExpansionReceipt = Get-Content -Raw -LiteralPath (Join-Path $toolExpansionProfile '.agents\file-deletion-safety-rules.install.json') -Encoding utf8 | ConvertFrom-Json -Depth 20
Assert-True -Condition ($toolExpansionApplyResult.ExitCode -eq 0 -and $toolExpansionApply.Status -eq 'APPLIED') -Message 'Adding a tool to a package-owned installation failed.'
Assert-True -Condition (@($toolExpansionReceipt.InstalledTools).Count -eq 2 -and @($toolExpansionReceipt.InstalledTools) -ccontains 'Codex' -and @($toolExpansionReceipt.InstalledTools) -ccontains 'Claude') -Message 'Adding a tool did not preserve the receipt tool set.'

$versionUpgradeProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$versionUpgradeReceiptPath = Join-Path $versionUpgradeProfile '.agents\file-deletion-safety-rules.install.json'
$versionUpgradeReceipt = Get-Content -Raw -LiteralPath $versionUpgradeReceiptPath -Encoding utf8 | ConvertFrom-Json -Depth 20
$versionUpgradeReceipt.PackageVersion = '1.0.0'
[IO.File]::WriteAllText($versionUpgradeReceiptPath, ($versionUpgradeReceipt | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
$versionUpgradePreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $versionUpgradeProfile)
$versionUpgradePreview = Convert-ResultJson -ProcessResult $versionUpgradePreviewResult
Assert-True -Condition ($versionUpgradePreviewResult.ExitCode -eq 0) -Message 'A valid receipt from another semantic version could not enter the generic upgrade path.'
Assert-True -Condition (@($versionUpgradePreview.Plan.Operations | Where-Object { $_.Kind -eq 'Receipt' -and $_.Action -eq 'Update' }).Count -eq 1) -Message 'The generic upgrade plan did not update the receipt version.'

$legacyProfile = New-TestProfile -TestRoot $testRoot
$legacySharedRoot = Join-Path $legacyProfile '.agents'
$legacyConfig = Join-Path $legacyProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory($legacySharedRoot) | Out-Null
[IO.Directory]::CreateDirectory((Split-Path -Parent $legacyConfig)) | Out-Null
$currentPolicySource = Join-Path $packageRoot 'policy\file-deletion-safety.md'
$currentHelperSource = Join-Path $packageRoot 'helpers\Recycle-Bin-Only.ps1'
$legacyPolicyTarget = Join-Path $legacySharedRoot 'file-deletion-safety.md'
$legacyHelperTarget = Join-Path $legacySharedRoot 'Recycle-Bin-Only.ps1'
[IO.File]::Copy($currentPolicySource, $legacyPolicyTarget, $false)
[IO.File]::Copy($currentHelperSource, $legacyHelperTarget, $false)
$legacyAdapter = (Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'adapters\codex.md') -Encoding utf8).Replace('{{POLICY_PATH}}', $legacyPolicyTarget)
[IO.File]::WriteAllText($legacyConfig, $legacyAdapter, [Text.UTF8Encoding]::new($false))
$legacyManifest = (Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding utf8 | ConvertFrom-Json -Depth 30)
$legacyManifest.legacyReceiptlessInstallations[0].policySha256 = (Get-FileHash -LiteralPath $legacyPolicyTarget -Algorithm SHA256).Hash
$legacyManifest.legacyReceiptlessInstallations[0].helperSha256 = (Get-FileHash -LiteralPath $legacyHelperTarget -Algorithm SHA256).Hash
$legacyPlan = New-InstallPlan -ProfileRoot $legacyProfile -SelectedTools @('Codex') -PackageRoot $packageRoot -Manifest $legacyManifest
Assert-True -Condition (@($legacyPlan.Plan.Operations | Where-Object { $_.Kind -eq 'Receipt' -and $_.Action -eq 'Create' }).Count -eq 1) -Message 'A proven receiptless legacy installation did not produce a receipt-creation plan.'

$legacyUnmanagedProfile = New-TestProfile -TestRoot $testRoot
$legacyUnmanagedSharedRoot = Join-Path $legacyUnmanagedProfile '.agents'
$legacyUnmanagedConfig = Join-Path $legacyUnmanagedProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory($legacyUnmanagedSharedRoot) | Out-Null
[IO.Directory]::CreateDirectory((Split-Path -Parent $legacyUnmanagedConfig)) | Out-Null
$legacyUnmanagedPolicyTarget = Join-Path $legacyUnmanagedSharedRoot 'file-deletion-safety.md'
$legacyUnmanagedHelperTarget = Join-Path $legacyUnmanagedSharedRoot 'Recycle-Bin-Only.ps1'
[IO.File]::Copy($currentPolicySource, $legacyUnmanagedPolicyTarget, $false)
[IO.File]::Copy($currentHelperSource, $legacyUnmanagedHelperTarget, $false)
$legacyUnmanagedTemplate = @'
## 0.1 文件安全删除规则会话开关

- 当前聊天/会话默认状态为 `ON`。
- 用户以直接命令明确表达关闭、启用或查询当前会话的文件安全删除规则时，Agent 应完成相应切换或仅报告状态；问句、引用、否定句或意图不明确时不得切换。Agent 不得自行切换。
- 切换后的状态反馈统一为 `文件安全删除规则：ON` 或 `文件安全删除规则：OFF（仅当前会话）`；状态不写入磁盘。
- `OFF` 仅适用于当前聊天/会话，不跨 Codex、Claude、OpenCode 共享；新会话、切换 Agent、上下文恢复后状态不明确时，自动视为 `ON`。
- 切换状态只影响切换后尚未开始的操作；不得改变已经展示、确认或执行中的删除任务。
- `ON` 时：涉及删除、清理、移除、回收站、永久清空、破坏性覆盖、截断、强制回滚、镜像同步或其他可能造成数据丢失的操作，必须完整读取并遵守 `{{POLICY_PATH}}`。该文件不存在或无法完整读取时必须停止；与其他规则冲突时采用限制更严格、可恢复性更高的规则。
- `OFF` 时：不读取也不适用 `{{POLICY_PATH}}`；本节和完整策略中的所有文件删除专项规则均暂停。当前会话回到未配置文件安全删除规则时的行为。
'@
$legacyUnmanagedText = "# Existing profile`n`n" + $legacyUnmanagedTemplate.Replace('{{POLICY_PATH}}', $legacyUnmanagedPolicyTarget) + "`n`n# Preserved section`n"
[IO.File]::WriteAllText($legacyUnmanagedConfig, $legacyUnmanagedText, [Text.UTF8Encoding]::new($false))
$legacyUnmanagedPlan = New-InstallPlan -ProfileRoot $legacyUnmanagedProfile -SelectedTools @('Codex') -PackageRoot $packageRoot -Manifest $legacyManifest
$legacyUnmanagedAdapterOperation = @($legacyUnmanagedPlan.Plan.Operations | Where-Object { $_.Kind -eq 'Adapter' -and $_.Tool -eq 'Codex' })
Assert-True -Condition ($legacyUnmanagedAdapterOperation.Count -eq 1 -and $legacyUnmanagedAdapterOperation[0].Action -eq 'Update') -Message 'An exact supported legacy unmanaged adapter did not produce an update plan.'
$legacyUnmanagedWrite = @($legacyUnmanagedPlan.Writes | Where-Object { [string]::Equals([string] $_.Path, $legacyUnmanagedConfig, [StringComparison]::OrdinalIgnoreCase) })
Assert-True -Condition ($legacyUnmanagedWrite.Count -eq 1) -Message 'The legacy unmanaged adapter update was not bound to a config write.'
$legacyUnmanagedDesiredText = [Text.UTF8Encoding]::new($false, $true).GetString($legacyUnmanagedWrite[0].Bytes)
Assert-True -Condition (-not $legacyUnmanagedDesiredText.Contains('## 0.1 文件安全删除规则会话开关') -and $legacyUnmanagedDesiredText.Contains('<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->')) -Message 'The legacy unmanaged adapter was not replaced by one managed block.'

[IO.File]::AppendAllText($legacyHelperTarget, "`nunknown legacy content`n", [Text.UTF8Encoding]::new($false))
$unknownLegacyRejected = $false
try {
    [void] (New-InstallPlan -ProfileRoot $legacyProfile -SelectedTools @('Codex') -PackageRoot $packageRoot -Manifest $legacyManifest)
} catch {
    $unknownLegacyRejected = $_.Exception.Message -like '*exact supported legacy installation*'
}
Assert-True -Condition $unknownLegacyRejected -Message 'An unknown receiptless policy/helper pair was accepted as a supported legacy installation.'

$partialProfile = New-TestProfile -TestRoot $testRoot
$partialSharedRoot = Join-Path $partialProfile '.agents'
[IO.Directory]::CreateDirectory($partialSharedRoot) | Out-Null
$partialPolicy = Join-Path $partialSharedRoot 'file-deletion-safety.md'
[IO.File]::WriteAllText($partialPolicy, "unknown policy`n", [Text.UTF8Encoding]::new($false))
$partialPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $partialProfile)
$partialPreview = Convert-ResultJson -ProcessResult $partialPreviewResult
Assert-True -Condition ($partialPreviewResult.ExitCode -ne 0 -and $partialPreview.Status -eq 'FAILED') -Message 'RED: installer accepted a partial set of shared installation files.'
Assert-True -Condition ((Get-Content -Raw -LiteralPath $partialPolicy -Encoding utf8) -eq "unknown policy`n") -Message 'Rejecting partial shared files changed the existing policy.'

$tamperedPolicyProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$tamperedPolicyPath = Join-Path $tamperedPolicyProfile '.agents\file-deletion-safety.md'
[IO.File]::AppendAllText($tamperedPolicyPath, "`nuser modification`n", [Text.UTF8Encoding]::new($false))
$tamperedPolicyPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $tamperedPolicyProfile)
$tamperedPolicyPreview = Convert-ResultJson -ProcessResult $tamperedPolicyPreviewResult
Assert-True -Condition ($tamperedPolicyPreviewResult.ExitCode -ne 0 -and $tamperedPolicyPreview.Status -eq 'FAILED') -Message 'RED: installer accepted a policy that no longer matches its receipt.'

$tamperedReceiptProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$tamperedReceiptPath = Join-Path $tamperedReceiptProfile '.agents\file-deletion-safety-rules.install.json'
$tamperedReceipt = Get-Content -Raw -LiteralPath $tamperedReceiptPath -Encoding utf8 | ConvertFrom-Json -Depth 20
$tamperedReceipt.PolicySha256 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
[IO.File]::WriteAllText($tamperedReceiptPath, ($tamperedReceipt | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
$tamperedReceiptPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $tamperedReceiptProfile)
$tamperedReceiptPreview = Convert-ResultJson -ProcessResult $tamperedReceiptPreviewResult
Assert-True -Condition ($tamperedReceiptPreviewResult.ExitCode -ne 0 -and $tamperedReceiptPreview.Status -eq 'FAILED') -Message 'RED: installer accepted a tampered installation receipt.'

$duplicateReceiptProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$duplicateReceiptPath = Join-Path $duplicateReceiptProfile '.agents\file-deletion-safety-rules.install.json'
$duplicateReceiptText = Get-Content -Raw -LiteralPath $duplicateReceiptPath -Encoding utf8
$duplicateReceiptText = $duplicateReceiptText.Replace('"SchemaVersion": 1,', '"SchemaVersion": 1,' + "`n" + '  "SchemaVersion": 1,')
[IO.File]::WriteAllText($duplicateReceiptPath, $duplicateReceiptText, [Text.UTF8Encoding]::new($false))
$duplicateReceiptPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $duplicateReceiptProfile)
$duplicateReceiptPreview = Convert-ResultJson -ProcessResult $duplicateReceiptPreviewResult
Assert-True -Condition ($duplicateReceiptPreviewResult.ExitCode -ne 0 -and $duplicateReceiptPreview.Status -eq 'FAILED') -Message 'RED: installer accepted duplicate JSON properties in the ownership receipt.'

$modifiedBlockProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$modifiedBlockPath = Join-Path $modifiedBlockProfile '.codex\AGENTS.md'
$modifiedBlockText = Get-Content -Raw -LiteralPath $modifiedBlockPath -Encoding utf8
$modifiedBlockText = $modifiedBlockText.Replace('当前聊天/会话默认状态为 `ON`', '当前聊天/会话默认状态为 `OFF`')
[IO.File]::WriteAllText($modifiedBlockPath, $modifiedBlockText, [Text.UTF8Encoding]::new($true))
$modifiedBlockPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $modifiedBlockProfile)
$modifiedBlockPreview = Convert-ResultJson -ProcessResult $modifiedBlockPreviewResult
Assert-True -Condition ($modifiedBlockPreviewResult.ExitCode -ne 0 -and $modifiedBlockPreview.Status -eq 'FAILED') -Message 'RED: installer accepted a user-modified managed block.'

$unownedManagedProfile = New-TestProfile -TestRoot $testRoot
$unownedManagedConfig = Join-Path $unownedManagedProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $unownedManagedConfig)) | Out-Null
$adapterTemplate = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'adapters\codex.md') -Encoding utf8
$unownedPolicyTarget = Join-Path $unownedManagedProfile '.agents\file-deletion-safety.md'
$unownedManagedText = $adapterTemplate.Replace('{{POLICY_PATH}}', $unownedPolicyTarget)
[IO.File]::WriteAllText($unownedManagedConfig, $unownedManagedText, [Text.UTF8Encoding]::new($false))
$unownedManagedPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $unownedManagedProfile)
$unownedManagedPreview = Convert-ResultJson -ProcessResult $unownedManagedPreviewResult
Assert-True -Condition ($unownedManagedPreviewResult.ExitCode -ne 0 -and $unownedManagedPreview.Status -eq 'FAILED') -Message 'RED: installer accepted a managed block without an ownership receipt.'

$driftProfile = New-TestProfile -TestRoot $testRoot
$driftConfig = Join-Path $driftProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $driftConfig)) | Out-Null
[IO.File]::WriteAllText($driftConfig, "before`n", [Text.UTF8Encoding]::new($false))
$driftPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $driftProfile)
$driftPreview = Convert-ResultJson -ProcessResult $driftPreviewResult
[IO.File]::AppendAllText($driftConfig, "drift`n", [Text.UTF8Encoding]::new($false))
$driftApplyResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $driftProfile, '-ExpectedPlanSha256', [string] $driftPreview.PlanSha256)
$driftApply = Convert-ResultJson -ProcessResult $driftApplyResult
Assert-True -Condition ($driftApplyResult.ExitCode -ne 0 -and $driftApply.Status -eq 'PLAN_MISMATCH') -Message 'Apply did not fail closed after Preview state drift.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $driftProfile '.agents\file-deletion-safety.md'))) -Message 'A state-drift rejection wrote the shared policy.'

$rollbackProfile = New-TestProfile -TestRoot $testRoot
$codexConfig = Join-Path $rollbackProfile '.codex\AGENTS.md'
$claudeConfig = Join-Path $rollbackProfile '.claude\CLAUDE.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $codexConfig)) | Out-Null
[IO.Directory]::CreateDirectory((Split-Path -Parent $claudeConfig)) | Out-Null
$codexOriginal = [Text.UTF8Encoding]::new($false).GetBytes("codex-before`n")
$claudeOriginal = [Text.UTF8Encoding]::new($false).GetBytes("claude-before`n")
[IO.File]::WriteAllBytes($codexConfig, $codexOriginal)
[IO.File]::WriteAllBytes($claudeConfig, $claudeOriginal)
$rollbackPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $rollbackProfile)
$rollbackPreview = Convert-ResultJson -ProcessResult $rollbackPreviewResult
$lockStream = [IO.File]::Open($claudeConfig, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $rollbackApplyResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Apply', '-Tool', 'All', '-UserProfileRoot', $rollbackProfile, '-ExpectedPlanSha256', [string] $rollbackPreview.PlanSha256)
} finally {
    $lockStream.Dispose()
}
$rollbackApply = Convert-ResultJson -ProcessResult $rollbackApplyResult
Assert-True -Condition ($rollbackApplyResult.ExitCode -ne 0 -and $rollbackApply.Status -eq 'ROLLED_BACK') -Message 'A mid-transaction write failure was not rolled back.'
Assert-True -Condition ([Convert]::ToHexString([IO.File]::ReadAllBytes($codexConfig)) -eq [Convert]::ToHexString($codexOriginal)) -Message 'Codex config bytes were not restored after rollback.'
Assert-True -Condition ([Convert]::ToHexString([IO.File]::ReadAllBytes($claudeConfig)) -eq [Convert]::ToHexString($claudeOriginal)) -Message 'Claude config bytes changed after rollback.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $rollbackProfile '.agents\file-deletion-safety.md'))) -Message 'Rollback left a newly created policy at its install path.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $rollbackProfile '.agents\Recycle-Bin-Only.ps1'))) -Message 'Rollback left a newly created helper at its install path.'

$unsupportedHeadings = @('## 0.1 删除保护', '## 0.1 文件安全删除规则会话开关', '## 文件安全删除规则会话开关')
foreach ($unsupportedHeading in $unsupportedHeadings) {
    $unsupportedProfile = New-TestProfile -TestRoot $testRoot
    $unsupportedConfig = Join-Path $unsupportedProfile '.codex\AGENTS.md'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $unsupportedConfig)) | Out-Null
    $unsupportedBytes = [Text.UTF8Encoding]::new($false).GetBytes("# Before`n`n$unsupportedHeading`nunmanaged content`n`n## After`nkeep me`n")
    [IO.File]::WriteAllBytes($unsupportedConfig, $unsupportedBytes)
    $unsupportedPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $unsupportedProfile)
    $unsupportedPreview = Convert-ResultJson -ProcessResult $unsupportedPreviewResult
    Assert-True -Condition ($unsupportedPreviewResult.ExitCode -ne 0 -and $unsupportedPreview.Status -eq 'FAILED') -Message "An unsupported unmanaged deletion-safety block was not rejected: $unsupportedHeading"
    Assert-True -Condition ([Convert]::ToHexString([IO.File]::ReadAllBytes($unsupportedConfig)) -eq [Convert]::ToHexString($unsupportedBytes)) -Message "Rejecting an unsupported unmanaged block changed the config: $unsupportedHeading"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $unsupportedProfile '.agents\file-deletion-safety.md'))) -Message "Rejecting an unsupported unmanaged block wrote shared files: $unsupportedHeading"
}

$mixedProfile = New-TestProfile -TestRoot $testRoot
$mixedConfig = Join-Path $mixedProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $mixedConfig)) | Out-Null
[IO.File]::WriteAllText($mixedConfig, "## 0.1 删除保护`nunmanaged content`n`n<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->`nstale`n<!-- FILE-DELETION-SAFETY-RULES:END -->`n", [Text.UTF8Encoding]::new($false))
$mixedPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $mixedProfile)
$mixedPreview = Convert-ResultJson -ProcessResult $mixedPreviewResult
Assert-True -Condition ($mixedPreviewResult.ExitCode -ne 0 -and $mixedPreview.Status -eq 'FAILED') -Message 'Coexisting unmanaged and managed blocks were not rejected.'

$orphanMarkerProfile = New-TestProfile -TestRoot $testRoot
$orphanMarkerConfig = Join-Path $orphanMarkerProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $orphanMarkerConfig)) | Out-Null
[IO.File]::WriteAllText($orphanMarkerConfig, "<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->`norphan`n", [Text.UTF8Encoding]::new($false))
$orphanMarkerPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $orphanMarkerProfile)
$orphanMarkerPreview = Convert-ResultJson -ProcessResult $orphanMarkerPreviewResult
Assert-True -Condition ($orphanMarkerPreviewResult.ExitCode -ne 0 -and $orphanMarkerPreview.Status -eq 'FAILED') -Message 'An unbalanced managed marker was not rejected.'

$duplicateManagedProfile = New-TestProfile -TestRoot $testRoot
$duplicateManagedConfig = Join-Path $duplicateManagedProfile '.codex\AGENTS.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $duplicateManagedConfig)) | Out-Null
$duplicateManagedBlock = "<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->`nstale`n<!-- FILE-DELETION-SAFETY-RULES:END -->"
[IO.File]::WriteAllText($duplicateManagedConfig, "$duplicateManagedBlock`n`n$duplicateManagedBlock`n", [Text.UTF8Encoding]::new($false))
$duplicateManagedPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $duplicateManagedProfile)
$duplicateManagedPreview = Convert-ResultJson -ProcessResult $duplicateManagedPreviewResult
Assert-True -Condition ($duplicateManagedPreviewResult.ExitCode -ne 0 -and $duplicateManagedPreview.Status -eq 'FAILED') -Message 'Duplicate managed blocks were not rejected.'

$junctionProfile = New-TestProfile -TestRoot $testRoot
$junctionTarget = Join-Path $testRoot ('junction-target-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
$junctionPath = Join-Path $junctionProfile '.agents'
New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
$junctionPreviewResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $junctionProfile)
$junctionPreview = Convert-ResultJson -ProcessResult $junctionPreviewResult
Assert-True -Condition ($junctionPreviewResult.ExitCode -ne 0 -and $junctionPreview.Status -eq 'FAILED') -Message 'RED: installer followed a nested junction outside the profile.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $junctionTarget 'file-deletion-safety.md'))) -Message 'Junction rejection wrote to the junction target.'

[pscustomobject]@{
    Passed = $true
    Test = 'InstallerTransactions'
    TestRoot = $testRoot
    Cases = 22
} | ConvertTo-Json -Compress
