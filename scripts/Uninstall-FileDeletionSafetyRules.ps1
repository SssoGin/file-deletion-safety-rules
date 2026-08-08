[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')]
    [string] $Mode = 'Preview',

    [ValidateSet('All', 'Codex', 'Claude', 'OpenCode')]
    [string[]] $Tool = @('All'),

    [string] $UserProfileRoot = [Environment]::GetFolderPath('UserProfile'),

    [switch] $RemoveSharedFiles
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
$beginMarker = [string] $manifest.managedMarkers.begin
$endMarker = [string] $manifest.managedMarkers.end
$pattern = '(?ms)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker) + '(\r?\n)?'
$plans = @()
$writes = @()

foreach ($toolName in $selectedTools) {
    $configPath = Join-Path $profileRoot ($manifest.tools.$toolName.config -replace '/', '\')
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $plans += [pscustomobject]@{ Tool = $toolName; Path = $configPath; Action = 'Absent' }
        continue
    }
    $rawBytes = [IO.File]::ReadAllBytes($configPath)
    $hasUtf8Bom = $rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF
    $current = Get-Content -Raw -LiteralPath $configPath
    $matches = [regex]::Matches($current, $pattern)
    if ($matches.Count -gt 1) {
        throw "Multiple managed blocks found in $configPath"
    }
    if ($matches.Count -eq 0) {
        $plans += [pscustomobject]@{ Tool = $toolName; Path = $configPath; Action = 'Unchanged' }
        continue
    }
    $managedMatch = $matches[0]
    $prefix = $current.Substring(0, $managedMatch.Index)
    $suffix = $current.Substring($managedMatch.Index + $managedMatch.Length)
    $newline = if ($current.Contains("`r`n")) { "`r`n" } else { "`n" }
    $separator = $newline + $newline
    if ($prefix.EndsWith($separator, [StringComparison]::Ordinal)) {
        $prefix = $prefix.Substring(0, $prefix.Length - $newline.Length)
    }
    $desired = $prefix + $suffix
    $plans += [pscustomobject]@{ Tool = $toolName; Path = $configPath; Action = 'RemoveManagedBlock' }
    $writes += [pscustomobject]@{ Path = $configPath; Text = $desired; HasUtf8Bom = $hasUtf8Bom }
}

$sharedRoot = Join-Path $profileRoot $manifest.sharedInstallDirectory
$policyTarget = Join-Path $sharedRoot $manifest.policy.installedName
$helperTarget = Join-Path $sharedRoot $manifest.helper.installedName
$plans += [pscustomobject]@{ Tool = $null; Path = $policyTarget; Action = if ($RemoveSharedFiles) { 'RemoveAfterAdapterCheck' } else { 'Keep' } }
$plans += [pscustomobject]@{ Tool = $null; Path = $helperTarget; Action = if ($RemoveSharedFiles) { 'RemoveAfterAdapterCheck' } else { 'Keep' } }

if ($Mode -eq 'Preview') {
    [pscustomobject]@{ Mode = 'Preview'; Plans = $plans } | ConvertTo-Json -Depth 6
    exit 0
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-file-deletion-safety-rules'
foreach ($write in $writes) {
    $backup = $write.Path + '.bak-' + $stamp
    [IO.File]::Copy($write.Path, $backup, $false)
    [IO.File]::WriteAllText($write.Path, [string] $write.Text, [Text.UTF8Encoding]::new([bool] $write.HasUtf8Bom))
}

if ($RemoveSharedFiles) {
    $remainingBlocks = @()
    foreach ($toolName in @('Codex', 'Claude', 'OpenCode')) {
        $configPath = Join-Path $profileRoot ($manifest.tools.$toolName.config -replace '/', '\')
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $content = Get-Content -Raw -LiteralPath $configPath
            if ($content.Contains($beginMarker) -or $content.Contains($endMarker)) {
                $remainingBlocks += $configPath
            }
        }
    }
    if ($remainingBlocks.Count -gt 0) {
        throw ('Shared files were kept because managed blocks remain: ' + ($remainingBlocks -join ', '))
    }
    if (Test-Path -LiteralPath $policyTarget -PathType Leaf) { Remove-Item -LiteralPath $policyTarget -ErrorAction Stop }
    if (Test-Path -LiteralPath $helperTarget -PathType Leaf) { Remove-Item -LiteralPath $helperTarget -ErrorAction Stop }
}

[pscustomobject]@{ Mode = 'Apply'; BackupSuffix = '.bak-' + $stamp; Plans = $plans } | ConvertTo-Json -Depth 6
