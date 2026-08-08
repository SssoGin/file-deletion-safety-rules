[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')]
    [string] $Mode = 'Preview',

    [ValidateSet('All', 'Codex', 'Claude', 'OpenCode')]
    [string[]] $Tool = @('All'),

    [string] $UserProfileRoot = [Environment]::GetFolderPath('UserProfile')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedProfileRoot {
    param([Parameter(Mandatory)][string] $Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'UserProfileRoot must be an absolute path.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ([string]::Equals($full, [IO.Path]::GetPathRoot($full).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A volume root cannot be used as UserProfileRoot.'
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "UserProfileRoot does not exist: $full"
    }
    return $full
}

function Get-SelectedTools {
    param([Parameter(Mandatory)][string[]] $Requested)

    if ($Requested -contains 'All') {
        return @('Codex', 'Claude', 'OpenCode')
    }
    return @($Requested | Select-Object -Unique)
}

function Get-TextInfo {
    param([Parameter(Mandatory)][string] $LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Text = ''; HasUtf8Bom = $true }
    }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Exists = $true; Text = $text; HasUtf8Bom = $hasBom }
}

function Get-DesiredConfigText {
    param(
        [Parameter(Mandatory)][string] $Current,
        [Parameter(Mandatory)][string] $ManagedBlock,
        [Parameter(Mandatory)][string] $BeginMarker,
        [Parameter(Mandatory)][string] $EndMarker
    )

    $newline = if ($Current.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = ($ManagedBlock -replace "`r?`n", $newline).TrimEnd([char[]]@("`r", "`n"))
    $pattern = '(?ms)' + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker)
    $matches = [regex]::Matches($Current, $pattern)
    if ($matches.Count -gt 1) {
        throw 'Multiple managed blocks were found; refusing to choose one automatically.'
    }
    if ($matches.Count -eq 1) {
        return [regex]::Replace($Current, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $block }, 1)
    }
    if ([string]::IsNullOrWhiteSpace($Current)) {
        return $block + $newline
    }
    return $Current.TrimEnd([char[]]@("`r", "`n")) + $newline + $newline + $block + $newline
}

function Write-BytesAtomic {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $BackupSuffix
    )

    $parent = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = Join-Path $parent ('.file-deletion-safety-rules-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllBytes($temp, $Bytes)
    try {
        if ([IO.File]::Exists($Destination)) {
            $backup = $Destination + $BackupSuffix
            [IO.File]::Replace($temp, $Destination, $backup, $true)
        } else {
            [IO.File]::Move($temp, $Destination)
        }
    } finally {
        if ([IO.File]::Exists($temp)) {
            [IO.File]::Delete($temp)
        }
    }
}

$profileRoot = Get-NormalizedProfileRoot -Path $UserProfileRoot
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $packageRoot 'manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 10
$selectedTools = Get-SelectedTools -Requested $Tool
$sharedRoot = Join-Path $profileRoot $manifest.sharedInstallDirectory
$policySource = Join-Path $packageRoot ($manifest.policy.source -replace '/', '\')
$helperSource = Join-Path $packageRoot ($manifest.helper.source -replace '/', '\')
$policyTarget = Join-Path $sharedRoot $manifest.policy.installedName
$helperTarget = Join-Path $sharedRoot $manifest.helper.installedName

$helperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $helperSource).Hash
if (-not [string]::Equals($helperHash, $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Package helper hash mismatch: $helperHash"
}

$beginMarker = [string] $manifest.managedMarkers.begin
$endMarker = [string] $manifest.managedMarkers.end
$plans = @()
$configWrites = @()

foreach ($toolName in $selectedTools) {
    $toolSpec = $manifest.tools.$toolName
    $configPath = Join-Path $profileRoot ($toolSpec.config -replace '/', '\')
    $adapterPath = Join-Path $packageRoot ($toolSpec.adapter -replace '/', '\')
    $managedBlock = (Get-Content -Raw -LiteralPath $adapterPath).Replace('{{POLICY_PATH}}', $policyTarget)
    $textInfo = Get-TextInfo -LiteralPath $configPath
    $desired = Get-DesiredConfigText -Current $textInfo.Text -ManagedBlock $managedBlock -BeginMarker $beginMarker -EndMarker $endMarker
    $changed = -not [string]::Equals($textInfo.Text, $desired, [StringComparison]::Ordinal)
    $plans += [pscustomobject]@{
        Kind = 'Adapter'
        Tool = $toolName
        Path = $configPath
        Action = if ($changed) { if ($textInfo.Exists) { 'Update' } else { 'Create' } } else { 'Unchanged' }
        ProposedManagedBlock = $managedBlock.TrimEnd()
    }
    if ($changed) {
        $configWrites += [pscustomobject]@{ Path = $configPath; Text = $desired; HasUtf8Bom = $textInfo.HasUtf8Bom }
    }
}

foreach ($shared in @(
    [pscustomobject]@{ Kind = 'Policy'; Source = $policySource; Target = $policyTarget },
    [pscustomobject]@{ Kind = 'Helper'; Source = $helperSource; Target = $helperTarget }
)) {
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $shared.Source).Hash
    $targetHash = if (Test-Path -LiteralPath $shared.Target -PathType Leaf) { (Get-FileHash -Algorithm SHA256 -LiteralPath $shared.Target).Hash } else { $null }
    $plans += [pscustomobject]@{
        Kind = $shared.Kind
        Tool = $null
        Path = $shared.Target
        Action = if ($null -eq $targetHash) { 'Create' } elseif ([string]::Equals($sourceHash, $targetHash, [StringComparison]::OrdinalIgnoreCase)) { 'Unchanged' } else { 'Update' }
        ProposedManagedBlock = $null
    }
}

if ($Mode -eq 'Preview') {
    [pscustomobject]@{ Mode = 'Preview'; UserProfileRoot = $profileRoot; Plans = $plans } | ConvertTo-Json -Depth 8
    exit 0
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-file-deletion-safety-rules'
$backupSuffix = '.bak-' + $stamp

foreach ($shared in @(
    [pscustomobject]@{ Source = $policySource; Target = $policyTarget },
    [pscustomobject]@{ Source = $helperSource; Target = $helperTarget }
)) {
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $shared.Source).Hash
    $targetHash = if (Test-Path -LiteralPath $shared.Target -PathType Leaf) { (Get-FileHash -Algorithm SHA256 -LiteralPath $shared.Target).Hash } else { $null }
    if ($null -eq $targetHash -or -not [string]::Equals($sourceHash, $targetHash, [StringComparison]::OrdinalIgnoreCase)) {
        Write-BytesAtomic -Bytes ([IO.File]::ReadAllBytes($shared.Source)) -Destination $shared.Target -BackupSuffix $backupSuffix
    }
}

foreach ($write in $configWrites) {
    $encoding = [Text.UTF8Encoding]::new([bool] $write.HasUtf8Bom)
    Write-BytesAtomic -Bytes $encoding.GetBytes([string] $write.Text) -Destination $write.Path -BackupSuffix $backupSuffix
}

[pscustomobject]@{ Mode = 'Apply'; UserProfileRoot = $profileRoot; BackupSuffix = $backupSuffix; Plans = $plans } | ConvertTo-Json -Depth 8
