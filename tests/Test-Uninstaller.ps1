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

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ProcessResult.Stdout)) -Message "Script emitted no JSON. stderr: $($ProcessResult.Stderr)"
    return $ProcessResult.Stdout | ConvertFrom-Json -Depth 20
}

function New-InstalledProfile {
    param(
        [Parameter(Mandatory)][string] $TestRoot,
        [Parameter(Mandatory)][string] $InstallerPath
    )

    $profileRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    $codexConfig = Join-Path $profileRoot '.codex\AGENTS.md'
    $claudeConfig = Join-Path $profileRoot '.claude\CLAUDE.md'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $codexConfig)) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path -Parent $claudeConfig)) | Out-Null
    [IO.File]::WriteAllText($codexConfig, "codex-outside`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($claudeConfig, "claude-outside`n", [Text.UTF8Encoding]::new($false))

    $previewResult = Invoke-PowerShellFile -LiteralPath $InstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $profileRoot)
    $preview = Convert-ResultJson -ProcessResult $previewResult
    Assert-True -Condition ($previewResult.ExitCode -eq 0) -Message 'Fixture installation Preview failed.'
    $applyResult = Invoke-PowerShellFile -LiteralPath $InstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'All', '-UserProfileRoot', $profileRoot, '-ExpectedPlanSha256', [string] $preview.PlanSha256)
    $apply = Convert-ResultJson -ProcessResult $applyResult
    Assert-True -Condition ($applyResult.ExitCode -eq 0 -and $apply.Status -eq 'APPLIED') -Message 'Fixture installation Apply failed.'
    return $profileRoot
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installerPath = Join-Path $packageRoot 'scripts\Install-FileDeletionSafetyRules.ps1'
$uninstallerPath = Join-Path $packageRoot 'scripts\Uninstall-FileDeletionSafetyRules.ps1'
$testRoot = Join-Path $packageRoot '.test-profile\uninstaller'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

$successProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$successPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $successProfile, '-RemoveSharedFiles')
$successPreview = Convert-ResultJson -ProcessResult $successPreviewResult
Assert-True -Condition ($successPreviewResult.ExitCode -eq 0 -and [string] $successPreview.PlanSha256 -match '^[A-F0-9]{64}$') -Message 'RED: uninstall Preview has no deterministic PlanSha256.'
$successApplyResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'All', '-UserProfileRoot', $successProfile, '-RemoveSharedFiles', '-ExpectedPlanSha256', [string] $successPreview.PlanSha256)
$successApply = Convert-ResultJson -ProcessResult $successApplyResult
Assert-True -Condition ($successApplyResult.ExitCode -eq 0 -and $successApply.Status -eq 'APPLIED') -Message 'Bound uninstall Apply failed.'
foreach ($sharedName in @('file-deletion-safety.md', 'Recycle-Bin-Only.ps1', 'file-deletion-safety-rules.install.json')) {
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $successProfile ".agents\$sharedName"))) -Message "Shared file remained after safe uninstall: $sharedName"
}
$codexAfter = Get-Content -Raw -LiteralPath (Join-Path $successProfile '.codex\AGENTS.md') -Encoding utf8
Assert-True -Condition ($codexAfter.Contains('codex-outside') -and -not $codexAfter.Contains('FILE-DELETION-SAFETY-RULES:BEGIN')) -Message 'Uninstall did not preserve Codex content outside the managed block.'
Assert-True -Condition (Test-Path -LiteralPath $successApply.BackupRoot -PathType Container) -Message 'Uninstall backup root is missing.'

$bomProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$bomConfig = Join-Path $bomProfile '.codex\AGENTS.md'
$bomConfigText = Get-Content -Raw -LiteralPath $bomConfig -Encoding utf8
[IO.File]::WriteAllText($bomConfig, $bomConfigText, [Text.UTF8Encoding]::new($true))
$bomPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $bomProfile)
$bomPreview = Convert-ResultJson -ProcessResult $bomPreviewResult
$bomApplyResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $bomProfile, '-ExpectedPlanSha256', [string] $bomPreview.PlanSha256)
$bomApply = Convert-ResultJson -ProcessResult $bomApplyResult
$bomAfterBytes = [IO.File]::ReadAllBytes($bomConfig)
Assert-True -Condition ($bomApplyResult.ExitCode -eq 0 -and $bomApply.Status -eq 'APPLIED') -Message 'BOM-preserving uninstall failed.'
Assert-True -Condition ($bomAfterBytes.Length -ge 3 -and $bomAfterBytes[0] -eq 0xEF -and $bomAfterBytes[1] -eq 0xBB -and $bomAfterBytes[2] -eq 0xBF) -Message 'Uninstall did not preserve the UTF-8 BOM.'

$modifiedProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$modifiedPolicy = Join-Path $modifiedProfile '.agents\file-deletion-safety.md'
[IO.File]::AppendAllText($modifiedPolicy, "`nuser modification`n", [Text.UTF8Encoding]::new($false))
$modifiedPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $modifiedProfile, '-RemoveSharedFiles')
$modifiedPreview = Convert-ResultJson -ProcessResult $modifiedPreviewResult
Assert-True -Condition ($modifiedPreviewResult.ExitCode -ne 0 -and $modifiedPreview.Status -eq 'FAILED') -Message 'Uninstall accepted a user-modified shared policy.'
Assert-True -Condition (Test-Path -LiteralPath $modifiedPolicy -PathType Leaf) -Message 'A user-modified policy was removed.'

$mixedProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$mixedConfig = Join-Path $mixedProfile '.codex\AGENTS.md'
[IO.File]::AppendAllText($mixedConfig, "`n## 0.1 删除保护`nunmanaged coexistence`n", [Text.UTF8Encoding]::new($false))
$mixedPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $mixedProfile)
$mixedPreview = Convert-ResultJson -ProcessResult $mixedPreviewResult
Assert-True -Condition ($mixedPreviewResult.ExitCode -ne 0 -and $mixedPreview.Status -eq 'FAILED') -Message 'RED: uninstall accepted coexisting unmanaged and managed deletion rules.'
Assert-True -Condition ((Get-Content -Raw -LiteralPath $mixedConfig -Encoding utf8).Contains('FILE-DELETION-SAFETY-RULES:BEGIN')) -Message 'Rejecting mixed rules changed the managed block.'

$rootPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', 'E:\', '-RemoveSharedFiles')
$rootPreview = Convert-ResultJson -ProcessResult $rootPreviewResult
Assert-True -Condition ($rootPreviewResult.ExitCode -ne 0 -and $rootPreview.Status -eq 'FAILED') -Message 'Uninstaller accepted a volume root as UserProfileRoot.'

$driftProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$driftPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $driftProfile)
$driftPreview = Convert-ResultJson -ProcessResult $driftPreviewResult
$driftConfig = Join-Path $driftProfile '.codex\AGENTS.md'
[IO.File]::AppendAllText($driftConfig, "drift`n", [Text.UTF8Encoding]::new($false))
$driftApplyResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $driftProfile, '-ExpectedPlanSha256', [string] $driftPreview.PlanSha256)
$driftApply = Convert-ResultJson -ProcessResult $driftApplyResult
Assert-True -Condition ($driftApplyResult.ExitCode -ne 0 -and $driftApply.Status -eq 'PLAN_MISMATCH') -Message 'Uninstall Apply did not reject state drift.'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $driftProfile '.agents\file-deletion-safety.md') -PathType Leaf) -Message 'State-drift rejection changed shared files.'

$rollbackProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$rollbackCodex = Join-Path $rollbackProfile '.codex\AGENTS.md'
$rollbackClaude = Join-Path $rollbackProfile '.claude\CLAUDE.md'
$rollbackCodexBefore = [IO.File]::ReadAllBytes($rollbackCodex)
$rollbackClaudeBefore = [IO.File]::ReadAllBytes($rollbackClaude)
$rollbackPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $rollbackProfile, '-RemoveSharedFiles')
$rollbackPreview = Convert-ResultJson -ProcessResult $rollbackPreviewResult
$lockStream = [IO.File]::Open($rollbackClaude, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $rollbackApplyResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'All', '-UserProfileRoot', $rollbackProfile, '-RemoveSharedFiles', '-ExpectedPlanSha256', [string] $rollbackPreview.PlanSha256)
} finally {
    $lockStream.Dispose()
}
$rollbackApply = Convert-ResultJson -ProcessResult $rollbackApplyResult
Assert-True -Condition ($rollbackApplyResult.ExitCode -ne 0 -and $rollbackApply.Status -eq 'ROLLED_BACK') -Message 'Uninstall write failure was not rolled back.'
Assert-True -Condition ([Convert]::ToHexString([IO.File]::ReadAllBytes($rollbackCodex)) -eq [Convert]::ToHexString($rollbackCodexBefore)) -Message 'Codex bytes were not restored after uninstall rollback.'
Assert-True -Condition ([Convert]::ToHexString([IO.File]::ReadAllBytes($rollbackClaude)) -eq [Convert]::ToHexString($rollbackClaudeBefore)) -Message 'Claude bytes changed after uninstall rollback.'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $rollbackProfile '.agents\file-deletion-safety.md') -PathType Leaf) -Message 'Uninstall rollback lost the shared policy.'

$junctionProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$junctionPath = Join-Path $junctionProfile '.agents'
$junctionTarget = Join-Path $testRoot ('junction-target-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::Move($junctionPath, $junctionTarget)
New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
$junctionPreviewResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $junctionProfile, '-RemoveSharedFiles')
$junctionPreview = Convert-ResultJson -ProcessResult $junctionPreviewResult
Assert-True -Condition ($junctionPreviewResult.ExitCode -ne 0 -and $junctionPreview.Status -eq 'FAILED') -Message 'RED: uninstaller followed a nested junction outside the profile.'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $junctionTarget 'file-deletion-safety.md') -PathType Leaf) -Message 'Junction rejection changed the external policy fixture.'

[pscustomobject]@{
    Passed = $true
    Test = 'UninstallerSafety'
    TestRoot = $testRoot
    Cases = 8
} | ConvertTo-Json -Compress
