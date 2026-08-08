[CmdletBinding()]
param(
    [ValidateSet('All', 'Codex', 'Claude', 'OpenCode')]
    [string[]] $Tool = @('All'),

    [string] $UserProfileRoot = [Environment]::GetFolderPath('UserProfile')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [IO.Path]::IsPathFullyQualified($UserProfileRoot)) {
    throw 'UserProfileRoot must be an absolute path.'
}
$profileRoot = [IO.Path]::GetFullPath($UserProfileRoot).TrimEnd('\', '/')
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') | ConvertFrom-Json -Depth 10
$selectedTools = if ($Tool -contains 'All') { @('Codex', 'Claude', 'OpenCode') } else { @($Tool | Select-Object -Unique) }
$sharedRoot = Join-Path $profileRoot $manifest.sharedInstallDirectory
$policyTarget = Join-Path $sharedRoot $manifest.policy.installedName
$helperTarget = Join-Path $sharedRoot $manifest.helper.installedName
$checks = @()

$packageHelper = Join-Path $packageRoot ($manifest.helper.source -replace '/', '\')
$packageHelperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packageHelper).Hash
$checks += [pscustomobject]@{ Check = 'PackageHelperHash'; Passed = [string]::Equals($packageHelperHash, $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase); Detail = $packageHelperHash }
$checks += [pscustomobject]@{ Check = 'InstalledPolicyExists'; Passed = Test-Path -LiteralPath $policyTarget -PathType Leaf; Detail = $policyTarget }
$installedHelperExists = Test-Path -LiteralPath $helperTarget -PathType Leaf
$installedHelperHash = if ($installedHelperExists) { (Get-FileHash -Algorithm SHA256 -LiteralPath $helperTarget).Hash } else { '' }
$checks += [pscustomobject]@{ Check = 'InstalledHelperHash'; Passed = $installedHelperExists -and [string]::Equals($installedHelperHash, $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase); Detail = $installedHelperHash }

foreach ($toolName in $selectedTools) {
    $configPath = Join-Path $profileRoot ($manifest.tools.$toolName.config -replace '/', '\')
    $exists = Test-Path -LiteralPath $configPath -PathType Leaf
    $content = if ($exists) { Get-Content -Raw -LiteralPath $configPath } else { '' }
    $hasOneBegin = ([regex]::Matches($content, [regex]::Escape([string] $manifest.managedMarkers.begin))).Count -eq 1
    $hasOneEnd = ([regex]::Matches($content, [regex]::Escape([string] $manifest.managedMarkers.end))).Count -eq 1
    $checks += [pscustomobject]@{ Check = "$toolName.ManagedBlock"; Passed = $exists -and $hasOneBegin -and $hasOneEnd -and $content.Contains($policyTarget) -and -not $content.Contains('{{POLICY_PATH}}'); Detail = $configPath }
}

$packageTextFiles = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object { $_.Extension -in @('.md', '.ps1', '.json') })
$packageTextPaths = @($packageTextFiles | ForEach-Object { $_.FullName })
$privateUserPathPattern = '(?i)[A-Z]:\\Users\\(?!Public(?:\\|\b)|Default(?: User)?(?:\\|\b)|All Users(?:\\|\b)|<[^>]+>)[^\\\s`"'']+'
$privatePathHits = @(Select-String -LiteralPath $packageTextPaths -Pattern $privateUserPathPattern -ErrorAction Stop)
$checks += [pscustomobject]@{ Check = 'NoPublisherUserPath'; Passed = $privatePathHits.Count -eq 0; Detail = @($privatePathHits | ForEach-Object { $_.Path }) }

$policyText = Get-Content -Raw -LiteralPath (Join-Path $packageRoot ($manifest.policy.source -replace '/', '\'))
$requiredErrors = @('EXPLORER_NOT_FOUND', 'SESSION_MISMATCH', 'IDENTITY_MISMATCH', 'IDENTITY_UNVERIFIABLE')
$missingErrors = @($requiredErrors | Where-Object { -not $policyText.Contains($_) })
$checks += [pscustomobject]@{ Check = 'RecycleEnvironmentErrorMapping'; Passed = $missingErrors.Count -eq 0; Detail = $missingErrors }

$bridgeTerms = @(
    'NamedPipe' + 'ServerStream'
    'New-' + 'Service'
    'schtasks' + '.exe'
    'Register-' + 'ScheduledTask'
)
$bridgeHits = @($packageTextFiles | Select-String -SimpleMatch $bridgeTerms -ErrorAction Stop)
$checks += [pscustomobject]@{ Check = 'NoDesktopBridge'; Passed = $bridgeHits.Count -eq 0; Detail = @($bridgeHits | ForEach-Object { $_.Path }) }

$passed = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
[pscustomobject]@{ Passed = $passed; Checks = $checks } | ConvertTo-Json -Depth 8
if (-not $passed) { exit 1 }
