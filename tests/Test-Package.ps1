[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testProfilePrefix = (Join-Path $packageRoot '.test-profile') + [IO.Path]::DirectorySeparatorChar
$quarantineSegment = [IO.Path]::DirectorySeparatorChar + '.deletion-quarantine' + [IO.Path]::DirectorySeparatorChar
$scripts = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter '*.ps1' -File | Where-Object {
    -not $_.FullName.StartsWith($testProfilePrefix, [StringComparison]::OrdinalIgnoreCase) -and
    -not $_.FullName.Contains($quarantineSegment, [StringComparison]::OrdinalIgnoreCase)
})
$parserErrors = @()
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref] $tokens, [ref] $errors) | Out-Null
    foreach ($errorItem in @($errors)) {
        $parserErrors += [pscustomobject]@{ Path = $script.FullName; Message = $errorItem.Message }
    }
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding utf8 | ConvertFrom-Json -Depth 10
$helperPath = Join-Path $packageRoot ($manifest.helper.source -replace '/', '\')
$helperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $helperPath).Hash
$policyPath = Join-Path $packageRoot ($manifest.policy.source -replace '/', '\')
$policyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $policyPath).Hash
$policyText = Get-Content -Raw -LiteralPath $policyPath -Encoding utf8
$requiredErrors = @('EXPLORER_NOT_FOUND', 'SESSION_MISMATCH', 'IDENTITY_MISMATCH', 'IDENTITY_UNVERIFIABLE')
$missingErrors = @($requiredErrors | Where-Object { -not $policyText.Contains($_) })
$adapterPaths = @($manifest.tools.PSObject.Properties | ForEach-Object { Join-Path $packageRoot ($_.Value.adapter -replace '/', '\') })
$adapterFailures = @($adapterPaths | Where-Object {
    $content = Get-Content -Raw -LiteralPath $_ -Encoding utf8
    -not ($content.Contains([string] $manifest.managedMarkers.begin) -and $content.Contains([string] $manifest.managedMarkers.end) -and $content.Contains('{{POLICY_PATH}}'))
})
$packageTextFiles = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object {
    $_.Extension -in @('.md', '.ps1', '.json', '.yml', '.yaml') -and
    -not $_.FullName.StartsWith($testProfilePrefix, [StringComparison]::OrdinalIgnoreCase) -and
    -not $_.FullName.Contains($quarantineSegment, [StringComparison]::OrdinalIgnoreCase) -and
    $_.FullName -notlike '*\.git\*'
})
$packageTextPaths = @($packageTextFiles | ForEach-Object { $_.FullName })
$privateUserPathPattern = '(?i)[A-Z]:\\Users\\(?!Public(?:\\|\b)|Default(?: User)?(?:\\|\b)|All Users(?:\\|\b)|<[^>]+>)[^\\\s`"'']+'
$privatePathHits = @(Select-String -LiteralPath $packageTextPaths -Pattern $privateUserPathPattern -ErrorAction Stop)
$forbiddenPublicArtifacts = @('PROJECT_HANDOFF.md')
$forbiddenPublicArtifactHits = @($forbiddenPublicArtifacts | Where-Object { Test-Path -LiteralPath (Join-Path $packageRoot $_) })
$bridgeTerms = @(
    'NamedPipe' + 'ServerStream'
    'New-' + 'Service'
    'schtasks' + '.exe'
    'Register-' + 'ScheduledTask'
)
$bridgeHits = @(Select-String -LiteralPath $packageTextPaths -SimpleMatch $bridgeTerms -ErrorAction Stop)
$legacyTerms = @(
    'file-' + 'safety-rules'
    'FILE-' + 'SAFETY-RULES'
    'File' + 'SafetyRules'
)
$legacyHits = @(Select-String -LiteralPath $packageTextPaths -SimpleMatch $legacyTerms -ErrorAction Stop)
$canonicalIdentity =
    [string]::Equals([string] $manifest.name, 'file-deletion-safety-rules', [StringComparison]::Ordinal) -and
    [string]::Equals([string] $manifest.managedMarkers.begin, '<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->', [StringComparison]::Ordinal) -and
    [string]::Equals([string] $manifest.managedMarkers.end, '<!-- FILE-DELETION-SAFETY-RULES:END -->', [StringComparison]::Ordinal)
$readmePath = Join-Path $packageRoot 'README.md'
$chineseReadmePath = Join-Path $packageRoot 'README.zh-CN.md'
$releaseNotesPath = Join-Path $packageRoot 'RELEASE_NOTES.md'
$documentationFilesExist =
    (Test-Path -LiteralPath $readmePath -PathType Leaf) -and
    (Test-Path -LiteralPath $chineseReadmePath -PathType Leaf) -and
    (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)
$englishReadme = if (Test-Path -LiteralPath $readmePath -PathType Leaf) { Get-Content -Raw -LiteralPath $readmePath -Encoding utf8 } else { '' }
$chineseReadme = if (Test-Path -LiteralPath $chineseReadmePath -PathType Leaf) { Get-Content -Raw -LiteralPath $chineseReadmePath -Encoding utf8 } else { '' }
$releaseNotes = if (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf) { Get-Content -Raw -LiteralPath $releaseNotesPath -Encoding utf8 } else { '' }
$readmeLanguageLinks =
    $englishReadme.Contains('[简体中文](README.zh-CN.md)') -and
    $chineseReadme.Contains('[English](README.md)')
$switchDocumentation =
    $englishReadme.Contains('Disable file deletion safety rules') -and
    $englishReadme.Contains('Enable file deletion safety rules') -and
    $englishReadme.Contains('Query file deletion safety rules status') -and
    $chineseReadme.Contains('关闭文件安全删除规则') -and
    $chineseReadme.Contains('启用文件安全删除规则') -and
    $chineseReadme.Contains('查询文件安全删除规则状态')
$transactionDocumentation =
    $englishReadme.Contains('ExpectedPlanSha256') -and
    $englishReadme.Contains('file-deletion-safety-rules.install.json') -and
    $englishReadme.Contains('unsupported unmanaged deletion-safety') -and
    $englishReadme.Contains('does not prove release provenance') -and
    $chineseReadme.Contains('ExpectedPlanSha256') -and
    $chineseReadme.Contains('file-deletion-safety-rules.install.json') -and
    $chineseReadme.Contains('不受支持的未托管删除安全规则') -and
    $chineseReadme.Contains('不能证明发布来源')
$releaseNotesCandidate =
    $releaseNotes.Contains('# v1.0.1') -and
    $releaseNotes.Contains('## English') -and
    $releaseNotes.Contains('## 简体中文') -and
    $releaseNotes.Contains($manifest.helper.sha256)

$requiredRuntimeFiles = @(
    'policy/file-deletion-safety.md',
    'helpers/Recycle-Bin-Only.ps1',
    'adapters/codex.md',
    'adapters/claude.md',
    'adapters/opencode.md',
    'scripts/Install-FileDeletionSafetyRules.ps1',
    'scripts/Uninstall-FileDeletionSafetyRules.ps1',
    'scripts/Verify-FileDeletionSafetyRules.ps1'
)
$manifestFileNames = @($manifest.files.PSObject.Properties | ForEach-Object { $_.Name })
$manifestFileCoverage =
    @($requiredRuntimeFiles | Where-Object { $manifestFileNames -notcontains $_ }).Count -eq 0 -and
    @($manifestFileNames | Where-Object { $requiredRuntimeFiles -notcontains $_ }).Count -eq 0
$manifestFileHashFailures = @($manifest.files.PSObject.Properties | ForEach-Object {
    $runtimePath = Join-Path $packageRoot ($_.Name -replace '/', '\')
    $actualHash = if (Test-Path -LiteralPath $runtimePath -PathType Leaf) { (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash } else { '' }
    if (-not [string]::Equals($actualHash, [string] $_.Value, [StringComparison]::OrdinalIgnoreCase)) {
        [pscustomobject]@{ Path = $_.Name; Expected = [string] $_.Value; Actual = $actualHash }
    }
})
$manifestIdentity =
    [int] $manifest.schemaVersion -eq 2 -and
    [string]::Equals([string] $manifest.version, '1.0.1', [StringComparison]::Ordinal) -and
    [string]::Equals([string] $manifest.name, 'file-deletion-safety-rules', [StringComparison]::Ordinal)
$policyHashPinned = [string]::Equals($policyHash, [string] $manifest.policy.sha256, [StringComparison]::OrdinalIgnoreCase)
$policyHelperBinding = $policyText.Contains([string] $manifest.helper.sha256) -and $policyText.Contains('`$R`')
$legacyV100 = @($manifest.legacyReceiptlessInstallations | Where-Object { $_.version -eq '1.0.0' })
$installerText = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'scripts\Install-FileDeletionSafetyRules.ps1') -Encoding utf8
$legacyMigrationContract =
    $legacyV100.Count -eq 1 -and
    [string]::Equals([string] $legacyV100[0].policySha256, 'D477A246B6B25B2619E1CD2792CEAF1851450DC2FB79AB4F5FC288023FC99614', [StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals([string] $legacyV100[0].helperSha256, 'AF7E87EC8E5B6160E85A2E8EB069DF23D6A91B6BE81E8B434F36FCF516867128', [StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals([string] $legacyV100[0].unmanagedAdapterSha256, '318EEC7CE229B13BF02C669C6F80F09AA30313F969384AA5BFC4CA61B428F26B', [StringComparison]::OrdinalIgnoreCase) -and
    $installerText.Contains('$isLegacyReceiptlessState') -and
    $installerText.Contains('Receiptless legacy shared files have no exact package-managed or supported unmanaged tool block')
$uninstallerText = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'scripts\Uninstall-FileDeletionSafetyRules.ps1') -Encoding utf8
$uninstallerHasNoPermanentDelete =
    -not $uninstallerText.Contains('Remove-' + 'Item') -and
    -not $uninstallerText.Contains('[IO.File]::' + 'Delete') -and
    -not $uninstallerText.Contains('[IO.Directory]::' + 'Delete')

function Invoke-IsolatedTest {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [string] $ProcessPath = (Get-Process -Id $PID).Path
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ProcessPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void] $startInfo.ArgumentList.Add('-NoProfile')
    [void] $startInfo.ArgumentList.Add('-File')
    [void] $startInfo.ArgumentList.Add($LiteralPath)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
        Path = $LiteralPath
        ExitCode = $process.ExitCode
        Stdout = $stdout.Trim()
        Stderr = $stderr.Trim()
    }
}

function Invoke-WindowsPowerShell51ParserTest {
    param([Parameter(Mandatory)][string] $PackageRoot)

    $escapedRoot = $PackageRoot.Replace("'", "''")
    $commandText = @"
Set-StrictMode -Version 3.0
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$packageRoot = '$escapedRoot'
`$testProfilePrefix = (Join-Path `$packageRoot '.test-profile') + [IO.Path]::DirectorySeparatorChar
`$scripts = @(Get-ChildItem -LiteralPath `$packageRoot -Recurse -Filter '*.ps1' -File | Where-Object { -not `$_.FullName.StartsWith(`$testProfilePrefix, [StringComparison]::OrdinalIgnoreCase) })
`$parserErrors = @()
foreach (`$script in `$scripts) {
    `$bytes = [IO.File]::ReadAllBytes(`$script.FullName)
    `$hasBom = `$bytes.Length -ge 3 -and `$bytes[0] -eq 0xEF -and `$bytes[1] -eq 0xBB -and `$bytes[2] -eq 0xBF
    `$offset = if (`$hasBom) { 3 } else { 0 }
    `$utf8 = New-Object Text.UTF8Encoding(`$false, `$true)
    `$scriptText = `$utf8.GetString(`$bytes, `$offset, `$bytes.Length - `$offset)
    `$tokens = `$null
    `$errors = `$null
    [Management.Automation.Language.Parser]::ParseInput(`$scriptText, [ref] `$tokens, [ref] `$errors) | Out-Null
    foreach (`$errorItem in @(`$errors)) {
        `$parserErrors += [pscustomobject]@{ Path = `$script.FullName; Message = `$errorItem.Message }
    }
}
if (`$parserErrors.Count -gt 0) {
    `$parserErrors | ConvertTo-Json -Depth 5
    exit 1
}
[pscustomobject]@{ Passed = `$true; Test = 'WindowsPowerShell51Parser'; Edition = `$PSVersionTable.PSEdition; Version = `$PSVersionTable.PSVersion.ToString(); ScriptCount = `$scripts.Count } | ConvertTo-Json -Compress
"@
    $tokens = $null
    $commandErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($commandText, [ref] $tokens, [ref] $commandErrors) | Out-Null
    if (@($commandErrors).Count -gt 0) {
        return [pscustomobject]@{ Path = 'WindowsPowerShell51Parser'; ExitCode = 1; Stdout = ''; Stderr = 'Generated parser command is invalid.' }
    }

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void] $startInfo.ArgumentList.Add('-NoProfile')
    [void] $startInfo.ArgumentList.Add('-NonInteractive')
    [void] $startInfo.ArgumentList.Add('-OutputFormat')
    [void] $startInfo.ArgumentList.Add('Text')
    [void] $startInfo.ArgumentList.Add('-EncodedCommand')
    [void] $startInfo.ArgumentList.Add($encodedCommand)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        Path = 'WindowsPowerShell51Parser'
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        Stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    }
}

$behaviorTestDefinitions = @(
    [pscustomobject]@{ Path = Join-Path $PSScriptRoot 'Test-ConfirmationCard.ps1'; ProcessPath = (Get-Process -Id $PID).Path },
    [pscustomobject]@{ Path = Join-Path $PSScriptRoot 'Test-HelperEvidence.ps1'; ProcessPath = (Get-Process -Id $PID).Path },
    [pscustomobject]@{ Path = Join-Path $PSScriptRoot 'Test-Installer.ps1'; ProcessPath = (Get-Process -Id $PID).Path },
    [pscustomobject]@{ Path = Join-Path $PSScriptRoot 'Test-Uninstaller.ps1'; ProcessPath = (Get-Process -Id $PID).Path },
    [pscustomobject]@{ Path = Join-Path $PSScriptRoot 'Test-Verifier.ps1'; ProcessPath = (Get-Process -Id $PID).Path },
    [pscustomobject]@{ Path = Join-Path $PSScriptRoot 'Test-ManifestContract.ps1'; ProcessPath = (Get-Process -Id $PID).Path }
)
$behaviorTestResults = @($behaviorTestDefinitions | ForEach-Object { Invoke-IsolatedTest -LiteralPath $_.Path -ProcessPath $_.ProcessPath })
$behaviorTestResults += Invoke-WindowsPowerShell51ParserTest -PackageRoot $packageRoot
$behaviorTestFailures = @($behaviorTestResults | Where-Object { $_.ExitCode -ne 0 -or -not [string]::IsNullOrEmpty($_.Stderr) })
$behaviorTestEvidence = @()
foreach ($testResult in $behaviorTestResults) {
    try {
        if ([string]::IsNullOrWhiteSpace($testResult.Stdout)) { throw 'Test emitted no JSON evidence.' }
        $evidence = $testResult.Stdout | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        if ($null -eq $evidence.PSObject.Properties['Passed'] -or -not [bool] $evidence.Passed) {
            throw 'Test evidence does not report Passed=true.'
        }
        $behaviorTestEvidence += $evidence
    } catch {
        $behaviorTestFailures += [pscustomobject]@{ Path = $testResult.Path; EvidenceError = $_.Exception.Message }
    }
}
$behaviorCaseCount = [int] (@($behaviorTestEvidence | Where-Object { $null -ne $_.PSObject.Properties['Cases'] } | Measure-Object -Property Cases -Sum).Sum)
if ($behaviorCaseCount -ne 48) {
    $behaviorTestFailures += [pscustomobject]@{ Path = 'BehaviorCaseCount'; Expected = 48; Actual = $behaviorCaseCount }
}

$checks = @(
    [pscustomobject]@{ Check = 'ScriptParser'; Passed = $parserErrors.Count -eq 0; Detail = $parserErrors },
    [pscustomobject]@{ Check = 'HelperHash'; Passed = [string]::Equals($helperHash, $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase); Detail = $helperHash },
    [pscustomobject]@{ Check = 'PolicyHash'; Passed = $policyHashPinned; Detail = $policyHash },
    [pscustomobject]@{ Check = 'ManifestIdentity'; Passed = $manifestIdentity; Detail = [pscustomobject]@{ SchemaVersion = $manifest.schemaVersion; Version = $manifest.version; Name = $manifest.name } },
    [pscustomobject]@{ Check = 'ManifestFileCoverage'; Passed = $manifestFileCoverage; Detail = $manifestFileNames },
    [pscustomobject]@{ Check = 'ManifestFileHashes'; Passed = $manifestFileHashFailures.Count -eq 0; Detail = $manifestFileHashFailures },
    [pscustomobject]@{ Check = 'PolicyHelperBinding'; Passed = $policyHelperBinding; Detail = $manifest.helper.sha256 },
    [pscustomobject]@{ Check = 'LegacyV100MigrationContract'; Passed = $legacyMigrationContract; Detail = $legacyV100 },
    [pscustomobject]@{ Check = 'UninstallerNoPermanentDelete'; Passed = $uninstallerHasNoPermanentDelete; Detail = (Join-Path $packageRoot 'scripts\Uninstall-FileDeletionSafetyRules.ps1') },
    [pscustomobject]@{ Check = 'PolicyErrorMapping'; Passed = $missingErrors.Count -eq 0; Detail = $missingErrors },
    [pscustomobject]@{ Check = 'AdapterTemplates'; Passed = $adapterFailures.Count -eq 0; Detail = $adapterFailures },
    [pscustomobject]@{ Check = 'NoPrivateUserProfilePath'; Passed = $privatePathHits.Count -eq 0; Detail = @($privatePathHits | ForEach-Object { [pscustomobject]@{ Path = $_.Path; LineNumber = $_.LineNumber; Match = $_.Matches.Value } }) },
    [pscustomobject]@{ Check = 'NoPrivateMaintainerArtifacts'; Passed = $forbiddenPublicArtifactHits.Count -eq 0; Detail = $forbiddenPublicArtifactHits },
    [pscustomobject]@{ Check = 'NoDesktopBridge'; Passed = $bridgeHits.Count -eq 0; Detail = @($bridgeHits | ForEach-Object { $_.Path }) },
    [pscustomobject]@{ Check = 'CanonicalPackageIdentity'; Passed = $canonicalIdentity; Detail = [string] $manifest.name },
    [pscustomobject]@{ Check = 'NoLegacyPackageIdentity'; Passed = $legacyHits.Count -eq 0; Detail = @($legacyHits | ForEach-Object { $_.Path }) },
    [pscustomobject]@{ Check = 'DocumentationFiles'; Passed = $documentationFilesExist; Detail = @($readmePath, $chineseReadmePath, $releaseNotesPath) },
    [pscustomobject]@{ Check = 'ReadmeLanguageLinks'; Passed = $readmeLanguageLinks; Detail = @($readmePath, $chineseReadmePath) },
    [pscustomobject]@{ Check = 'SessionSwitchDocumentation'; Passed = $switchDocumentation; Detail = @($readmePath, $chineseReadmePath) },
    [pscustomobject]@{ Check = 'TransactionDocumentation'; Passed = $transactionDocumentation; Detail = @($readmePath, $chineseReadmePath) },
    [pscustomobject]@{ Check = 'ReleaseNotesCandidate'; Passed = $releaseNotesCandidate; Detail = $releaseNotesPath }
    [pscustomobject]@{ Check = 'BehaviorTests'; Passed = $behaviorTestFailures.Count -eq 0; Detail = [pscustomobject]@{ CaseCount = $behaviorCaseCount; Evidence = $behaviorTestEvidence; Failures = $behaviorTestFailures; Results = $behaviorTestResults } }
)
$passed = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
[pscustomobject]@{ Passed = $passed; Checks = $checks } | ConvertTo-Json -Depth 8
if (-not $passed) { exit 1 }
