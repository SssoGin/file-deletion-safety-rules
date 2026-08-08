[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scripts = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'scripts') -Filter '*.ps1' -File)
$parserErrors = @()
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref] $tokens, [ref] $errors) | Out-Null
    foreach ($errorItem in @($errors)) {
        $parserErrors += [pscustomobject]@{ Path = $script.FullName; Message = $errorItem.Message }
    }
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') | ConvertFrom-Json -Depth 10
$helperPath = Join-Path $packageRoot ($manifest.helper.source -replace '/', '\')
$helperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $helperPath).Hash
$policyPath = Join-Path $packageRoot ($manifest.policy.source -replace '/', '\')
$policyText = Get-Content -Raw -LiteralPath $policyPath
$requiredErrors = @('EXPLORER_NOT_FOUND', 'SESSION_MISMATCH', 'IDENTITY_MISMATCH', 'IDENTITY_UNVERIFIABLE')
$missingErrors = @($requiredErrors | Where-Object { -not $policyText.Contains($_) })
$adapterPaths = @($manifest.tools.PSObject.Properties | ForEach-Object { Join-Path $packageRoot ($_.Value.adapter -replace '/', '\') })
$adapterFailures = @($adapterPaths | Where-Object {
    $content = Get-Content -Raw -LiteralPath $_
    -not ($content.Contains([string] $manifest.managedMarkers.begin) -and $content.Contains([string] $manifest.managedMarkers.end) -and $content.Contains('{{POLICY_PATH}}'))
})
$packageTextFiles = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object { $_.Extension -in @('.md', '.ps1', '.json') })
$packageTextPaths = @($packageTextFiles | ForEach-Object { $_.FullName })
$privateUserPathPattern = '(?i)[A-Z]:\\Users\\(?!Public(?:\\|\b)|Default(?: User)?(?:\\|\b)|All Users(?:\\|\b)|<[^>]+>)[^\\\s`"'']+'
$privatePathHits = @(Select-String -LiteralPath $packageTextPaths -Pattern $privateUserPathPattern -ErrorAction Stop)
$bridgeTerms = @(
    'NamedPipe' + 'ServerStream'
    'New-' + 'Service'
    'schtasks' + '.exe'
    'Register-' + 'ScheduledTask'
)
$bridgeHits = @($packageTextFiles | Select-String -SimpleMatch $bridgeTerms -ErrorAction Stop)
$legacyTerms = @(
    'file-' + 'safety-rules'
    'FILE-' + 'SAFETY-RULES'
    'File' + 'SafetyRules'
)
$legacyHits = @($packageTextFiles | Select-String -SimpleMatch $legacyTerms -ErrorAction Stop)
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
$englishReadme = if (Test-Path -LiteralPath $readmePath -PathType Leaf) { Get-Content -Raw -LiteralPath $readmePath } else { '' }
$chineseReadme = if (Test-Path -LiteralPath $chineseReadmePath -PathType Leaf) { Get-Content -Raw -LiteralPath $chineseReadmePath } else { '' }
$releaseNotes = if (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf) { Get-Content -Raw -LiteralPath $releaseNotesPath } else { '' }
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
$releaseNotesCandidate =
    $releaseNotes.Contains('# v1.0.0') -and
    $releaseNotes.Contains('## English') -and
    $releaseNotes.Contains('## 简体中文') -and
    $releaseNotes.Contains($manifest.helper.sha256)

$checks = @(
    [pscustomobject]@{ Check = 'ScriptParser'; Passed = $parserErrors.Count -eq 0; Detail = $parserErrors },
    [pscustomobject]@{ Check = 'HelperHash'; Passed = [string]::Equals($helperHash, $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase); Detail = $helperHash },
    [pscustomobject]@{ Check = 'PolicyErrorMapping'; Passed = $missingErrors.Count -eq 0; Detail = $missingErrors },
    [pscustomobject]@{ Check = 'AdapterTemplates'; Passed = $adapterFailures.Count -eq 0; Detail = $adapterFailures },
    [pscustomobject]@{ Check = 'NoPublisherUserPath'; Passed = $privatePathHits.Count -eq 0; Detail = @($privatePathHits | ForEach-Object { $_.Path }) },
    [pscustomobject]@{ Check = 'NoDesktopBridge'; Passed = $bridgeHits.Count -eq 0; Detail = @($bridgeHits | ForEach-Object { $_.Path }) },
    [pscustomobject]@{ Check = 'CanonicalPackageIdentity'; Passed = $canonicalIdentity; Detail = [string] $manifest.name },
    [pscustomobject]@{ Check = 'NoLegacyPackageIdentity'; Passed = $legacyHits.Count -eq 0; Detail = @($legacyHits | ForEach-Object { $_.Path }) },
    [pscustomobject]@{ Check = 'DocumentationFiles'; Passed = $documentationFilesExist; Detail = @($readmePath, $chineseReadmePath, $releaseNotesPath) },
    [pscustomobject]@{ Check = 'ReadmeLanguageLinks'; Passed = $readmeLanguageLinks; Detail = @($readmePath, $chineseReadmePath) },
    [pscustomobject]@{ Check = 'SessionSwitchDocumentation'; Passed = $switchDocumentation; Detail = @($readmePath, $chineseReadmePath) },
    [pscustomobject]@{ Check = 'ReleaseNotesCandidate'; Passed = $releaseNotesCandidate; Detail = $releaseNotesPath }
)
$passed = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
[pscustomobject]@{ Passed = $passed; Checks = $checks } | ConvertTo-Json -Depth 8
if (-not $passed) { exit 1 }
