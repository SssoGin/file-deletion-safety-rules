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

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $packageRoot '.test-profile\manifest-contract'
$fixtureRoot = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
[IO.Directory]::CreateDirectory($profileRoot) | Out-Null

$manifestPath = Join-Path $packageRoot 'manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding utf8 | ConvertFrom-Json -Depth 30
$runtimePaths = @($manifest.files.PSObject.Properties | ForEach-Object { [string] $_.Name })
foreach ($relativePath in $runtimePaths) {
    $sourcePath = Join-Path $packageRoot ($relativePath -replace '/', '\')
    $targetPath = Join-Path $fixtureRoot ($relativePath -replace '/', '\')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath)) | Out-Null
    [IO.File]::Copy($sourcePath, $targetPath, $false)
}

$manifest.files.PSObject.Properties.Remove('adapters/opencode.md')
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'manifest.json'), ($manifest | ConvertTo-Json -Depth 30) + "`n", [Text.UTF8Encoding]::new($false))

$installerPath = Join-Path $fixtureRoot 'scripts\Install-FileDeletionSafetyRules.ps1'
$installerResult = Invoke-PowerShellFile -LiteralPath $installerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $profileRoot)
$installer = Convert-ResultJson -ProcessResult $installerResult
Assert-True -Condition ($installerResult.ExitCode -ne 0 -and $installer.Status -eq 'FAILED') -Message 'RED: installer accepted a manifest with a missing runtime-file entry.'

$originalInstallerPath = Join-Path $packageRoot 'scripts\Install-FileDeletionSafetyRules.ps1'
$installPreviewResult = Invoke-PowerShellFile -LiteralPath $originalInstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $profileRoot)
$installPreview = Convert-ResultJson -ProcessResult $installPreviewResult
Assert-True -Condition ($installPreviewResult.ExitCode -eq 0) -Message 'Manifest-contract fixture Preview failed.'
$installApplyResult = Invoke-PowerShellFile -LiteralPath $originalInstallerPath -Arguments @('-Mode', 'Apply', '-Tool', 'Codex', '-UserProfileRoot', $profileRoot, '-ExpectedPlanSha256', [string] $installPreview.PlanSha256)
$installApply = Convert-ResultJson -ProcessResult $installApplyResult
Assert-True -Condition ($installApplyResult.ExitCode -eq 0 -and $installApply.Status -eq 'APPLIED') -Message 'Manifest-contract fixture Apply failed.'

$uninstallerPath = Join-Path $fixtureRoot 'scripts\Uninstall-FileDeletionSafetyRules.ps1'
$uninstallerResult = Invoke-PowerShellFile -LiteralPath $uninstallerPath -Arguments @('-Mode', 'Preview', '-Tool', 'Codex', '-UserProfileRoot', $profileRoot)
$uninstaller = Convert-ResultJson -ProcessResult $uninstallerResult
Assert-True -Condition ($uninstallerResult.ExitCode -ne 0 -and $uninstaller.Status -eq 'FAILED') -Message 'RED: uninstaller accepted a manifest with a missing runtime-file entry.'

$verifierPath = Join-Path $fixtureRoot 'scripts\Verify-FileDeletionSafetyRules.ps1'
$verifierResult = Invoke-PowerShellFile -LiteralPath $verifierPath -Arguments @('-Tool', 'Codex', '-UserProfileRoot', $profileRoot)
$verifier = Convert-ResultJson -ProcessResult $verifierResult
Assert-True -Condition ($verifierResult.ExitCode -ne 0 -and -not $verifier.Passed) -Message 'RED: verifier accepted a manifest with a missing runtime-file entry.'

[pscustomobject]@{
    Passed = $true
    Test = 'ManifestContract'
    TestRoot = $testRoot
    Cases = 3
} | ConvertTo-Json -Compress
