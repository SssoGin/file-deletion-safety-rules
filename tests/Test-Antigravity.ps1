[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-PackageScript {
    param([string] $Name, [string[]] $Arguments, [switch] $AllowFailure)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $packageRoot ('scripts\' + $Name))) + $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($stdout)) -Message "$Name emitted no JSON: $stderr"
    $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Data = ($stdout | ConvertFrom-Json -Depth 30) }
    if (-not $AllowFailure) {
        Assert-True -Condition ($process.ExitCode -eq 0 -and [string]::IsNullOrEmpty($stderr)) -Message "$Name failed: $stdout $stderr"
    }
    return $result
}

function Invoke-BoundTransaction {
    param([string] $Name, [string] $Profile, [string] $Tool, [switch] $RemoveShared)
    $baseArguments = @('-Tool', $Tool, '-UserProfileRoot', $Profile)
    if ($RemoveShared) { $baseArguments += '-RemoveSharedFiles' }
    $preview = Invoke-PackageScript -Name $Name -Arguments (@('-Mode', 'Preview') + $baseArguments)
    $applied = Invoke-PackageScript -Name $Name -Arguments (@('-Mode', 'Apply') + $baseArguments + @('-ExpectedPlanSha256', [string] $preview.Data.PlanSha256))
    Assert-True -Condition ($applied.Data.Status -eq 'APPLIED') -Message "$Name did not apply its bound plan."
    return $applied.Data
}

function New-FixtureProfile {
    $profile = Join-Path $testRoot ('profile with spaces-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($profile) | Out-Null
    return $profile
}

function Read-Receipt {
    param([string] $Profile)
    return Get-Content -Raw -LiteralPath (Join-Path $Profile '.agents\file-deletion-safety-rules.install.json') -Encoding utf8 | ConvertFrom-Json
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding utf8 | ConvertFrom-Json
$testRoot = Join-Path $packageRoot '.test-profile\antigravity'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$cases = [Collections.Generic.List[string]]::new()
$installer = 'Install-FileDeletionSafetyRules.ps1'
$uninstaller = 'Uninstall-FileDeletionSafetyRules.ps1'
$verifier = 'Verify-FileDeletionSafetyRules.ps1'

$singleProfile = New-FixtureProfile
$singleConfig = Join-Path $singleProfile '.gemini\GEMINI.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $singleConfig)) | Out-Null
$originalText = "# Existing synthetic rules`r`n`r`nKeep synthetic-user-rule.`r`n"
[IO.File]::WriteAllText($singleConfig, $originalText, [Text.UTF8Encoding]::new($true))
$singleInstall = Invoke-BoundTransaction -Name $installer -Profile $singleProfile -Tool Antigravity
$singleBytes = [IO.File]::ReadAllBytes($singleConfig)
$singleText = Get-Content -Raw -LiteralPath $singleConfig -Encoding utf8
$singleReceipt = Read-Receipt -Profile $singleProfile
Assert-True -Condition ($singleBytes[0] -eq 0xEF -and $singleBytes[1] -eq 0xBB -and $singleBytes[2] -eq 0xBF) -Message 'Antigravity installation lost the UTF-8 BOM.'
Assert-True -Condition ($singleText.StartsWith($originalText.TrimEnd([char[]]@("`r", "`n")) + "`r`n`r`n")) -Message 'Existing Antigravity text or CRLF style changed.'
Assert-True -Condition (@($singleReceipt.InstalledTools).Count -eq 1 -and $singleReceipt.InstalledTools[0] -eq 'Antigravity' -and $singleReceipt.PackageVersion -eq $manifest.version) -Message 'Antigravity-only receipt is incorrect.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $singleProfile '.codex\AGENTS.md'))) -Message 'Antigravity-only installation modified another tool.'
$cases.Add('AntigravityOnlyPreservesContentBomAndNewlines')

$singleHash = (Get-FileHash -LiteralPath $singleConfig).Hash
$repeated = Invoke-BoundTransaction -Name $installer -Profile $singleProfile -Tool Antigravity
$singleVerification = Invoke-PackageScript -Name $verifier -Arguments @('-Tool', 'Antigravity', '-UserProfileRoot', $singleProfile)
Assert-True -Condition ($null -eq $repeated.BackupRoot -and (Get-FileHash -LiteralPath $singleConfig).Hash -eq $singleHash -and $singleVerification.Data.Passed) -Message 'Antigravity installation is not idempotent or does not verify.'
$cases.Add('AntigravityOnlyIsIdempotentAndVerifies')

$upgradeProfile = New-FixtureProfile
$foreignConfig = Join-Path $upgradeProfile '.gemini\config\AGENTS.md'
[IO.Directory]::CreateDirectory((Split-Path -Parent $foreignConfig)) | Out-Null
[IO.File]::WriteAllText($foreignConfig, "# Unrelated synthetic global rules`nPreserve this file.`n", [Text.UTF8Encoding]::new($false))
$foreignHash = (Get-FileHash -LiteralPath $foreignConfig).Hash
$allInstall = Invoke-BoundTransaction -Name $installer -Profile $upgradeProfile -Tool All
$removeForOldFixture = Invoke-BoundTransaction -Name $uninstaller -Profile $upgradeProfile -Tool Antigravity
$oldReceipt = Read-Receipt -Profile $upgradeProfile
Assert-True -Condition (@($oldReceipt.InstalledTools).Count -eq 4) -Message 'The upgrade fixture is not a four-tool installation.'
$oldReceipt.PackageVersion = '1.2.0'
$upgradeReceiptPath = Join-Path $upgradeProfile '.agents\file-deletion-safety-rules.install.json'
[IO.File]::WriteAllText($upgradeReceiptPath, ($oldReceipt | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
$oldToolHashes = @('Codex', 'Claude', 'OpenCode', 'DeepSeekHarness') | ForEach-Object {
    Get-FileHash -LiteralPath (Join-Path $upgradeProfile $manifest.tools.$_.config)
}
$upgraded = Invoke-BoundTransaction -Name $installer -Profile $upgradeProfile -Tool All
$upgradedReceipt = Read-Receipt -Profile $upgradeProfile
$allVerification = Invoke-PackageScript -Name $verifier -Arguments @('-Tool', 'All', '-UserProfileRoot', $upgradeProfile)
Assert-True -Condition (@($upgradedReceipt.InstalledTools).Count -eq 5 -and $upgradedReceipt.InstalledTools -ccontains 'Antigravity' -and $upgradedReceipt.PackageVersion -eq $manifest.version -and $allVerification.Data.Passed) -Message 'The 1.2.0 four-tool installation did not upgrade to all five tools.'
foreach ($oldToolHash in $oldToolHashes) {
    Assert-True -Condition ((Get-FileHash -LiteralPath $oldToolHash.Path).Hash -eq $oldToolHash.Hash) -Message 'Adding Antigravity changed an existing tool.'
}
Assert-True -Condition ((Get-FileHash -LiteralPath $foreignConfig).Hash -eq $foreignHash) -Message 'Adding Antigravity changed another global rule file.'
$cases.Add('FourTool120UpgradePreservesExistingAndForeignRules')

$upgradeConfig = Join-Path $upgradeProfile '.gemini\GEMINI.md'
$cleanBytes = [IO.File]::ReadAllBytes($upgradeConfig)
[IO.File]::AppendAllText($upgradeConfig, "`n<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->`nextra block`n<!-- FILE-DELETION-SAFETY-RULES:END -->`n", [Text.UTF8Encoding]::new($false))
$tamperedVerification = Invoke-PackageScript -Name $verifier -Arguments @('-Tool', 'Antigravity', '-UserProfileRoot', $upgradeProfile) -AllowFailure
$tamperedUninstall = Invoke-PackageScript -Name $uninstaller -Arguments @('-Mode', 'Preview', '-Tool', 'Antigravity', '-UserProfileRoot', $upgradeProfile) -AllowFailure
Assert-True -Condition ($tamperedVerification.ExitCode -ne 0 -and -not $tamperedVerification.Data.Passed -and $tamperedUninstall.ExitCode -ne 0) -Message 'Modified or duplicated Antigravity rules were accepted.'
[IO.File]::WriteAllBytes($upgradeConfig, $cleanBytes)
$cases.Add('AntigravityTamperingIsRejectedBeforeUninstall')

$unsafeSharedRemoval = Invoke-PackageScript -Name $uninstaller -Arguments @('-Mode', 'Preview', '-Tool', 'Antigravity', '-UserProfileRoot', $upgradeProfile, '-RemoveSharedFiles') -AllowFailure
Assert-True -Condition ($unsafeSharedRemoval.ExitCode -ne 0 -and (Test-Path -LiteralPath (Join-Path $upgradeProfile '.agents\Recycle-Bin-Only.ps1'))) -Message 'Shared files can be removed while four other tools depend on them.'
$cases.Add('SharedFilesRemainProtectedWhileOtherToolsAreInstalled')

$partialUninstall = Invoke-BoundTransaction -Name $uninstaller -Profile $upgradeProfile -Tool Antigravity
$remainingReceipt = Read-Receipt -Profile $upgradeProfile
$remainingVerification = Invoke-PackageScript -Name $verifier -Arguments @('-Tool', 'Codex', '-UserProfileRoot', $upgradeProfile)
Assert-True -Condition (@($remainingReceipt.InstalledTools).Count -eq 4 -and $remainingReceipt.InstalledTools -cnotcontains 'Antigravity' -and $remainingVerification.Data.Passed -and -not (Get-Content -Raw -LiteralPath $upgradeConfig).Contains('FILE-DELETION-SAFETY-RULES:BEGIN')) -Message 'Antigravity-only uninstall damaged shared ownership or left its block.'
Assert-True -Condition ((Get-FileHash -LiteralPath $foreignConfig).Hash -eq $foreignHash) -Message 'Partial uninstall changed unrelated global rules.'
$cases.Add('PartialUninstallLeavesFourToolsAndSharedFilesValid')

$lastUninstall = Invoke-BoundTransaction -Name $uninstaller -Profile $singleProfile -Tool Antigravity -RemoveShared
$afterSingleText = Get-Content -Raw -LiteralPath $singleConfig -Encoding utf8
Assert-True -Condition ($afterSingleText.Contains('synthetic-user-rule') -and -not $afterSingleText.Contains('FILE-DELETION-SAFETY-RULES:BEGIN')) -Message 'Uninstall removed existing user rules or retained the managed block.'
foreach ($sharedName in @('file-deletion-safety.md', 'Recycle-Bin-Only.ps1', 'file-deletion-safety-rules.install.json')) {
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $singleProfile ('.agents\' + $sharedName)))) -Message 'Last-tool uninstall retained a selected shared file.'
}
Assert-True -Condition (Test-Path -LiteralPath $lastUninstall.BackupRoot -PathType Container) -Message 'Removed shared files have no transaction backup.'
$cases.Add('LastToolUninstallPreservesUserRulesAndRecoveryBackup')

$linkedProfile = New-FixtureProfile
$outsideProfile = New-FixtureProfile
$outsideConfig = Join-Path $outsideProfile 'GEMINI.md'
[IO.File]::WriteAllText($outsideConfig, "# Outside synthetic rules`n", [Text.UTF8Encoding]::new($false))
$outsideHash = (Get-FileHash -LiteralPath $outsideConfig).Hash
New-Item -ItemType Junction -Path (Join-Path $linkedProfile '.gemini') -Target $outsideProfile | Out-Null
$linkedPreview = Invoke-PackageScript -Name $installer -Arguments @('-Mode', 'Preview', '-Tool', 'Antigravity', '-UserProfileRoot', $linkedProfile) -AllowFailure
Assert-True -Condition ($linkedPreview.ExitCode -ne 0 -and (Get-FileHash -LiteralPath $outsideConfig).Hash -eq $outsideHash) -Message 'A linked Antigravity path was followed or its target was changed.'
$cases.Add('LinkedAntigravityProfileIsRejectedWithoutChangingTarget')

[pscustomobject]@{ Passed = $true; Test = 'AntigravitySupport'; Cases = $cases.Count; CaseNames = @($cases) } | ConvertTo-Json -Depth 4 -Compress
