[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) { throw $Message }
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
    foreach ($argument in $Arguments) { [void] $startInfo.ArgumentList.Add($argument) }
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
    [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    $previewResult = Invoke-PowerShellFile -LiteralPath $InstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'All', '-UserProfileRoot', $profileRoot)
    $preview = Convert-ResultJson -ProcessResult $previewResult
    $applyResult = Invoke-PowerShellFile -LiteralPath $InstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'All', '-UserProfileRoot', $profileRoot, '-ExpectedPlanSha256', [string] $preview.PlanSha256)
    $apply = Convert-ResultJson -ProcessResult $applyResult
    Assert-True -Condition ($applyResult.ExitCode -eq 0 -and $apply.Status -eq 'APPLIED') -Message 'Verifier fixture installation failed.'
    return $profileRoot
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installerPath = Join-Path $packageRoot 'scripts\Install-FileDeletionSafetyRules.ps1'
$verifierPath = Join-Path $packageRoot 'scripts\Verify-FileDeletionSafetyRules.ps1'
$testRoot = Join-Path $packageRoot '.test-profile\verifier'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

$validProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$validResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'All', '-UserProfileRoot', $validProfile)
$valid = Convert-ResultJson -ProcessResult $validResult
Assert-True -Condition ($validResult.ExitCode -eq 0 -and $valid.Passed -and $valid.PackageVersion -eq '1.0.1') -Message 'A valid installation did not verify with its package version.'

$policyProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$policyPath = Join-Path $policyProfile '.agents\file-deletion-safety.md'
[IO.File]::AppendAllText($policyPath, "`ntampered`n", [Text.UTF8Encoding]::new($false))
$policyResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'All', '-UserProfileRoot', $policyProfile)
$policyVerification = Convert-ResultJson -ProcessResult $policyResult
Assert-True -Condition ($policyResult.ExitCode -ne 0 -and -not $policyVerification.Passed) -Message 'RED: verifier accepted a tampered installed policy.'

$adapterProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$adapterPath = Join-Path $adapterProfile '.codex\AGENTS.md'
$adapterText = Get-Content -Raw -LiteralPath $adapterPath -Encoding utf8
$adapterText = $adapterText.Replace('当前聊天/会话默认状态为 `ON`', '当前聊天/会话默认状态为 `OFF`')
[IO.File]::WriteAllText($adapterPath, $adapterText, [Text.UTF8Encoding]::new($true))
$adapterResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'All', '-UserProfileRoot', $adapterProfile)
$adapterVerification = Convert-ResultJson -ProcessResult $adapterResult
Assert-True -Condition ($adapterResult.ExitCode -ne 0 -and -not $adapterVerification.Passed) -Message 'Verifier accepted a tampered managed block.'

$receiptProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$receiptPath = Join-Path $receiptProfile '.agents\file-deletion-safety-rules.install.json'
$receiptText = Get-Content -Raw -LiteralPath $receiptPath -Encoding utf8
$receiptText = $receiptText.Replace('"PackageVersion": "1.0.1"', '"PackageVersion": "9.9.9"')
[IO.File]::WriteAllText($receiptPath, $receiptText, [Text.UTF8Encoding]::new($false))
$receiptResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'All', '-UserProfileRoot', $receiptProfile)
$receiptVerification = Convert-ResultJson -ProcessResult $receiptResult
Assert-True -Condition ($receiptResult.ExitCode -ne 0 -and -not $receiptVerification.Passed) -Message 'Verifier accepted a tampered installation receipt.'

$mixedProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$mixedPath = Join-Path $mixedProfile '.codex\AGENTS.md'
[IO.File]::AppendAllText($mixedPath, "`n## 0.1 删除保护`nunmanaged coexistence`n", [Text.UTF8Encoding]::new($false))
$mixedResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'All', '-UserProfileRoot', $mixedProfile)
$mixedVerification = Convert-ResultJson -ProcessResult $mixedResult
Assert-True -Condition ($mixedResult.ExitCode -ne 0 -and -not $mixedVerification.Passed) -Message 'RED: verifier accepted coexisting unmanaged and managed deletion-safety rules.'

$junctionProfile = New-InstalledProfile -TestRoot $testRoot -InstallerPath $installerPath
$junctionPath = Join-Path $junctionProfile '.agents'
$junctionTarget = Join-Path $testRoot ('junction-target-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::Move($junctionPath, $junctionTarget)
New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
$junctionResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'All', '-UserProfileRoot', $junctionProfile)
$junctionVerification = Convert-ResultJson -ProcessResult $junctionResult
Assert-True -Condition ($junctionResult.ExitCode -ne 0 -and -not $junctionVerification.Passed) -Message 'RED: verifier followed a nested junction outside the profile.'

[pscustomobject]@{
    Passed = $true
    Test = 'VerifierIntegrity'
    TestRoot = $testRoot
    Cases = 6
} | ConvertTo-Json -Compress
