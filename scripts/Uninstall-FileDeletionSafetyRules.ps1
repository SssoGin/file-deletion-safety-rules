[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')]
    [string] $Mode = 'Preview',

    [ValidateSet('All', 'Codex', 'Claude', 'OpenCode')]
    [string[]] $Tool = @('All'),

    [string] $UserProfileRoot = [Environment]::GetFolderPath('UserProfile'),

    [switch] $RemoveSharedFiles,

    [string] $ExpectedPlanSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function Get-NormalizedProfileRoot {
    param([Parameter(Mandatory)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.Length -lt 3 -or
        -not [char]::IsLetter($Path[0]) -or
        $Path[1] -ne ':' -or
        ($Path[2] -ne '\' -and $Path[2] -ne '/')) {
        throw 'UserProfileRoot must be a fully qualified local-drive path.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $root = [IO.Path]::GetPathRoot($full).TrimEnd([char[]]@('\', '/'))
    if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A volume root cannot be used as UserProfileRoot.'
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "UserProfileRoot does not exist: $full"
    }

    $cursor = $full
    while (-not [string]::IsNullOrEmpty($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "UserProfileRoot traverses a reparse point: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parent
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

function Assert-NoReparseTraversal {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][string] $Label
    )

    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $normalizedPath = [IO.Path]::GetFullPath($LiteralPath)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not [string]::Equals($normalizedPath, $normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its allowed root: $LiteralPath"
    }

    $cursor = $normalizedPath
    while ($true) {
        $attributes = $null
        try {
            $attributes = [IO.File]::GetAttributes($cursor)
        } catch [IO.FileNotFoundException] {
            $attributes = $null
        } catch [IO.DirectoryNotFoundException] {
            $attributes = $null
        } catch {
            throw "$Label could not verify path attributes at ${cursor}: $($_.Exception.Message)"
        }
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$Label traverses a reparse point: $cursor"
        }
        if ([string]::Equals($cursor, $normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or [string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label could not prove containment for: $LiteralPath"
        }
        $cursor = $parent
    }
}

function Resolve-ChildPath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][string] $Label
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Label must be a non-empty relative path."
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Root ($RelativePath -replace '/', '\')))
    $rootPrefix = $Root.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its allowed root: $RelativePath"
    }
    Assert-NoReparseTraversal -Root $Root -LiteralPath $resolved -Label $Label
    return $resolved
}

function Get-UnsupportedUnmanagedHeadings {
    param([Parameter(Mandatory)][psobject] $Manifest)

    $property = $Manifest.PSObject.Properties['unsupportedUnmanagedHeadings']
    if ($null -eq $property) {
        throw 'Manifest unsupportedUnmanagedHeadings is missing.'
    }

    $headings = @($property.Value | ForEach-Object { [string] $_ })
    if ($headings.Count -eq 0) {
        throw 'Manifest unsupportedUnmanagedHeadings must not be empty.'
    }

    $validated = [Collections.Generic.List[string]]::new()
    foreach ($heading in $headings) {
        if ([string]::IsNullOrWhiteSpace($heading) -or $heading.Contains("`r") -or $heading.Contains("`n")) {
            throw 'Manifest unsupportedUnmanagedHeadings contains an invalid heading.'
        }
        if ($validated.Contains($heading)) {
            throw 'Manifest unsupportedUnmanagedHeadings contains a duplicate heading.'
        }
        $validated.Add($heading)
    }
    return @($validated)
}

function Test-ContainsUnsupportedUnmanagedHeading {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][string[]] $Headings,
        [AllowEmptyString()][string] $BeginMarker = '',
        [AllowEmptyString()][string] $EndMarker = ''
    )

    $textToScan = $Text
    if (-not [string]::IsNullOrEmpty($BeginMarker) -and -not [string]::IsNullOrEmpty($EndMarker)) {
        $managedPattern = '(?ms)' + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker)
        $textToScan = [regex]::Replace($textToScan, $managedPattern, '')
    }
    foreach ($heading in $Headings) {
        $pattern = '(?m)^' + [regex]::Escape($heading) + '[ \t]*\r?$'
        if ([regex]::IsMatch($textToScan, $pattern)) {
            return $true
        }
    }
    return $false
}

function Get-LegacyReceiptlessInstallations {
    param([Parameter(Mandatory)][psobject] $Manifest)

    $property = $Manifest.PSObject.Properties['legacyReceiptlessInstallations']
    if ($null -eq $property) { throw 'Manifest legacyReceiptlessInstallations is missing.' }
    $entries = @($property.Value)
    if ($entries.Count -eq 0) { throw 'Manifest legacyReceiptlessInstallations must not be empty.' }

    $versions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $validated = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $properties = @($entry.PSObject.Properties)
        $required = @('version', 'policySha256', 'helperSha256', 'unmanagedAdapterSha256')
        if ($properties.Count -ne $required.Count -or @($properties | Where-Object { $required -cnotcontains [string] $_.Name }).Count -ne 0) {
            throw 'Manifest legacyReceiptlessInstallations contains an unsupported schema.'
        }
        $version = [string] $entry.version
        $policySha256 = [string] $entry.policySha256
        $helperSha256 = [string] $entry.helperSha256
        $unmanagedAdapterSha256 = [string] $entry.unmanagedAdapterSha256
        if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$' -or
            $policySha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            $helperSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            $unmanagedAdapterSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            -not $versions.Add($version)) {
            throw 'Manifest legacyReceiptlessInstallations contains invalid or duplicate data.'
        }
        $validated.Add([pscustomobject]@{ Version = $version; PolicySha256 = $policySha256.ToUpperInvariant(); HelperSha256 = $helperSha256.ToUpperInvariant(); UnmanagedAdapterSha256 = $unmanagedAdapterSha256.ToUpperInvariant() })
    }
    return @($validated)
}

function Assert-ManifestContract {
    param(
        [Parameter(Mandatory)][string] $PackageRoot,
        [Parameter(Mandatory)][psobject] $Manifest
    )

    if ([int] $Manifest.schemaVersion -ne 2 -or
        -not [string]::Equals([string] $Manifest.name, 'file-deletion-safety-rules', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.platform, 'windows', [StringComparison]::Ordinal) -or
        [string] $Manifest.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw 'Package manifest identity is invalid.'
    }
    if (-not [string]::Equals([string] $Manifest.sharedInstallDirectory, '.agents', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.policy.source, 'policy/file-deletion-safety.md', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.policy.installedName, 'file-deletion-safety.md', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.helper.source, 'helpers/Recycle-Bin-Only.ps1', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.helper.installedName, 'Recycle-Bin-Only.ps1', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.receipt.installedName, 'file-deletion-safety-rules.install.json', [StringComparison]::Ordinal)) {
        throw 'Package manifest install paths are invalid.'
    }
    if (-not [string]::Equals([string] $Manifest.managedMarkers.begin, '<!-- FILE-DELETION-SAFETY-RULES:BEGIN -->', [StringComparison]::Ordinal) -or
        -not [string]::Equals([string] $Manifest.managedMarkers.end, '<!-- FILE-DELETION-SAFETY-RULES:END -->', [StringComparison]::Ordinal)) {
        throw 'Package manifest managed markers are invalid.'
    }

    $expectedTools = [ordered]@{
        Codex = [pscustomobject]@{ Config = '.codex/AGENTS.md'; Adapter = 'adapters/codex.md' }
        Claude = [pscustomobject]@{ Config = '.claude/CLAUDE.md'; Adapter = 'adapters/claude.md' }
        OpenCode = [pscustomobject]@{ Config = '.config/opencode/AGENTS.md'; Adapter = 'adapters/opencode.md' }
    }
    $toolProperties = @($Manifest.tools.PSObject.Properties)
    if ($toolProperties.Count -ne $expectedTools.Count) {
        throw 'Package manifest tool set is incomplete or contains unsupported tools.'
    }
    foreach ($toolProperty in $toolProperties) {
        if (@($expectedTools.Keys | Where-Object { [string]::Equals([string] $_, [string] $toolProperty.Name, [StringComparison]::Ordinal) }).Count -ne 1) {
            throw "Package manifest contains an unsupported tool: $($toolProperty.Name)"
        }
    }
    foreach ($toolName in $expectedTools.Keys) {
        $toolProperty = @($toolProperties | Where-Object { [string]::Equals([string] $_.Name, [string] $toolName, [StringComparison]::Ordinal) })
        if ($toolProperty.Count -ne 1 -or
            -not [string]::Equals([string] $toolProperty[0].Value.config, [string] $expectedTools[$toolName].Config, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string] $toolProperty[0].Value.adapter, [string] $expectedTools[$toolName].Adapter, [StringComparison]::Ordinal)) {
            throw "Package manifest paths are invalid for tool: $toolName"
        }
    }

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
    $fileProperties = @($Manifest.files.PSObject.Properties)
    if ($fileProperties.Count -ne $requiredRuntimeFiles.Count) {
        throw 'Package manifest runtime file set is incomplete or contains unsupported entries.'
    }
    foreach ($fileProperty in $fileProperties) {
        if (@($requiredRuntimeFiles | Where-Object { [string]::Equals([string] $_, [string] $fileProperty.Name, [StringComparison]::Ordinal) }).Count -ne 1) {
            throw "Package manifest contains an unsupported runtime file: $($fileProperty.Name)"
        }
        if ([string] $fileProperty.Value -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Package manifest contains an invalid SHA-256: $($fileProperty.Name)"
        }
    }
    foreach ($relativePath in $requiredRuntimeFiles) {
        $fileProperty = @($fileProperties | Where-Object { [string]::Equals([string] $_.Name, $relativePath, [StringComparison]::Ordinal) })
        if ($fileProperty.Count -ne 1) {
            throw "Package manifest runtime file is missing: $relativePath"
        }
        $filePath = Resolve-ChildPath -Root $PackageRoot -RelativePath $relativePath -Label 'files entry'
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Package file is missing: $relativePath"
        }
        $actualHash = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($filePath))
        if (-not [string]::Equals($actualHash, [string] $fileProperty[0].Value, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package file hash mismatch: $relativePath"
        }
    }

    $policyFile = @($fileProperties | Where-Object { [string]::Equals([string] $_.Name, 'policy/file-deletion-safety.md', [StringComparison]::Ordinal) })[0]
    $helperFile = @($fileProperties | Where-Object { [string]::Equals([string] $_.Name, 'helpers/Recycle-Bin-Only.ps1', [StringComparison]::Ordinal) })[0]
    if ([string] $Manifest.policy.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        -not [string]::Equals([string] $Manifest.policy.sha256, [string] $policyFile.Value, [StringComparison]::OrdinalIgnoreCase) -or
        [string] $Manifest.helper.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        -not [string]::Equals([string] $Manifest.helper.sha256, [string] $helperFile.Value, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Package manifest policy/helper hashes are not bound to the runtime file set.'
    }

    $unsupportedHeadings = @(Get-UnsupportedUnmanagedHeadings -Manifest $Manifest)
    $requiredUnsupportedHeadings = @('## 0.1 删除保护', '## 0.1 文件安全删除规则会话开关', '## 文件安全删除规则会话开关')
    if (@($requiredUnsupportedHeadings | Where-Object { $unsupportedHeadings -cnotcontains $_ }).Count -ne 0) {
        throw 'Package manifest does not declare every required unsupported unmanaged heading.'
    }

    $legacyInstallations = @(Get-LegacyReceiptlessInstallations -Manifest $Manifest)
    $legacyV100 = @($legacyInstallations | Where-Object { [string]::Equals([string] $_.Version, '1.0.0', [StringComparison]::Ordinal) })
    if ($legacyV100.Count -ne 1 -or
        -not [string]::Equals([string] $legacyV100[0].PolicySha256, 'D477A246B6B25B2619E1CD2792CEAF1851450DC2FB79AB4F5FC288023FC99614', [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string] $legacyV100[0].HelperSha256, 'AF7E87EC8E5B6160E85A2E8EB069DF23D6A91B6BE81E8B434F36FCF516867128', [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string] $legacyV100[0].UnmanagedAdapterSha256, '318EEC7CE229B13BF02C669C6F80F09AA30313F969384AA5BFC4CA61B428F26B', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Package manifest does not declare the exact supported v1.0.0 receiptless installation.'
    }
}

function Get-StrictTextInfo {
    param([Parameter(Mandatory)][string] $LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [pscustomobject]@{ Exists = $false; Bytes = [byte[]]::new(0); Text = ''; HasUtf8Bom = $true }
    }
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Expected a regular file: $LiteralPath"
    }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Exists = $true; Bytes = $bytes; Text = $text; HasUtf8Bom = $hasBom }
}

function Get-PathState {
    param([Parameter(Mandatory)][string] $LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [pscustomobject]@{ Exists = $false; Sha256 = $null; Length = [long] 0 }
    }
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Expected a regular file: $LiteralPath"
    }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    return [pscustomobject]@{ Exists = $true; Sha256 = Get-Sha256Hex -Bytes $bytes; Length = [long] $bytes.Length }
}

function Test-StateMatches {
    param(
        [Parameter(Mandatory)][psobject] $Expected,
        [Parameter(Mandatory)][psobject] $Actual
    )

    if ([bool] $Expected.Exists -ne [bool] $Actual.Exists) { return $false }
    if (-not [bool] $Expected.Exists) { return $true }
    return [string]::Equals([string] $Expected.Sha256, [string] $Actual.Sha256, [StringComparison]::OrdinalIgnoreCase) -and
        [long] $Expected.Length -eq [long] $Actual.Length
}

function Get-ExpectedManagedBlock {
    param(
        [Parameter(Mandatory)][string] $AdapterPath,
        [Parameter(Mandatory)][string] $PolicyTarget,
        [Parameter(Mandatory)][string] $Newline
    )

    $adapterInfo = Get-StrictTextInfo -LiteralPath $AdapterPath
    return ($adapterInfo.Text.Replace('{{POLICY_PATH}}', $PolicyTarget) -replace "`r?`n", $Newline).TrimEnd([char[]]@("`r", "`n"))
}

function Get-ManagedBlockResult {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Current,
        [Parameter(Mandatory)][string] $ExpectedBlock,
        [Parameter(Mandatory)][string] $BeginMarker,
        [Parameter(Mandatory)][string] $EndMarker,
        [Parameter(Mandatory)][string[]] $UnsupportedUnmanagedHeadings
    )

    $beginCount = ([regex]::Matches($Current, [regex]::Escape($BeginMarker))).Count
    $endCount = ([regex]::Matches($Current, [regex]::Escape($EndMarker))).Count
    if (($beginCount -gt 0 -or $endCount -gt 0) -and
        (Test-ContainsUnsupportedUnmanagedHeading -Text $Current -Headings $UnsupportedUnmanagedHeadings -BeginMarker $BeginMarker -EndMarker $EndMarker)) {
        throw 'Unsupported unmanaged and managed deletion-safety rules coexist; refusing to remove either one.'
    }
    if ($beginCount -eq 0 -and $endCount -eq 0) {
        return [pscustomobject]@{ Exists = $false; Desired = $Current }
    }
    if ($beginCount -ne 1 -or $endCount -ne 1) {
        throw 'Managed block markers are missing, duplicated, or unbalanced.'
    }

    $pattern = '(?ms)' + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker)
    $matches = [regex]::Matches($Current, $pattern)
    if ($matches.Count -ne 1 -or -not [string]::Equals($matches[0].Value, $ExpectedBlock, [StringComparison]::Ordinal)) {
        throw 'The managed block differs from this package; refusing to remove user-modified content.'
    }

    $prefix = $Current.Substring(0, $matches[0].Index)
    $suffix = $Current.Substring($matches[0].Index + $matches[0].Length)
    if ($prefix.EndsWith("`r`n`r`n", [StringComparison]::Ordinal) -and $suffix.StartsWith("`r`n", [StringComparison]::Ordinal)) {
        $suffix = $suffix.Substring(2)
    } elseif ($prefix.EndsWith("`n`n", [StringComparison]::Ordinal) -and $suffix.StartsWith("`n", [StringComparison]::Ordinal)) {
        $suffix = $suffix.Substring(1)
    }
    return [pscustomobject]@{ Exists = $true; Desired = $prefix + $suffix }
}

function Convert-TextToBytes {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][bool] $HasUtf8Bom
    )

    $body = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (-not $HasUtf8Bom) {
        return ,$body
    }

    $bytes = [byte[]]::new($body.Length + 3)
    $bytes[0] = 0xEF
    $bytes[1] = 0xBB
    $bytes[2] = 0xBF
    [Array]::Copy($body, 0, $bytes, 3, $body.Length)
    return ,$bytes
}

function New-ReceiptBytes {
    param(
        [Parameter(Mandatory)][psobject] $Manifest,
        [Parameter(Mandatory)][string] $PolicyHash,
        [Parameter(Mandatory)][string] $HelperHash,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $InstalledTools
    )

    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 1
        PackageName = [string] $Manifest.name
        PackageVersion = [string] $Manifest.version
        PolicySha256 = $PolicyHash
        HelperSha256 = $HelperHash
        InstalledTools = @($InstalledTools)
    }
    return ,([Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 8) + "`n"))
}

function New-UninstallPlan {
    param(
        [Parameter(Mandatory)][string] $ProfileRoot,
        [Parameter(Mandatory)][string[]] $SelectedTools,
        [Parameter(Mandatory)][string] $PackageRoot,
        [Parameter(Mandatory)][psobject] $Manifest,
        [Parameter(Mandatory)][bool] $RemoveShared
    )

    $sharedRoot = Resolve-ChildPath -Root $ProfileRoot -RelativePath ([string] $Manifest.sharedInstallDirectory) -Label 'sharedInstallDirectory'
    $policyTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $Manifest.policy.installedName) -Label 'policy.installedName'
    $helperTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $Manifest.helper.installedName) -Label 'helper.installedName'
    $receiptTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $Manifest.receipt.installedName) -Label 'receipt.installedName'
    $policyState = Get-PathState -LiteralPath $policyTarget
    $helperState = Get-PathState -LiteralPath $helperTarget
    $receiptState = Get-PathState -LiteralPath $receiptTarget
    if (-not $policyState.Exists -or -not $helperState.Exists -or -not $receiptState.Exists) {
        throw 'The policy, helper, and installation receipt must all exist before uninstall.'
    }
    if (-not [string]::Equals([string] $policyState.Sha256, [string] $Manifest.policy.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installed policy was modified or is not owned by this package.'
    }
    if (-not [string]::Equals([string] $helperState.Sha256, [string] $Manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installed helper was modified or is not owned by this package.'
    }

    $beginMarker = [string] $Manifest.managedMarkers.begin
    $endMarker = [string] $Manifest.managedMarkers.end
    $unsupportedUnmanagedHeadings = @(Get-UnsupportedUnmanagedHeadings -Manifest $Manifest)
    $actualInstalledTools = [Collections.Generic.List[string]]::new()
    $adapterResults = [Collections.Generic.List[object]]::new()
    foreach ($toolName in @('Codex', 'Claude', 'OpenCode')) {
        $toolSpec = $Manifest.tools.$toolName
        $configPath = Resolve-ChildPath -Root $ProfileRoot -RelativePath ([string] $toolSpec.config) -Label "$toolName.config"
        $configInfo = Get-StrictTextInfo -LiteralPath $configPath
        if (-not $configInfo.Exists) {
            continue
        }
        $newline = if ($configInfo.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $adapterPath = Resolve-ChildPath -Root $PackageRoot -RelativePath ([string] $toolSpec.adapter) -Label "$toolName.adapter"
        $expectedBlock = Get-ExpectedManagedBlock -AdapterPath $adapterPath -PolicyTarget $policyTarget -Newline $newline
        $blockResult = Get-ManagedBlockResult -Current $configInfo.Text -ExpectedBlock $expectedBlock -BeginMarker $beginMarker -EndMarker $endMarker -UnsupportedUnmanagedHeadings $unsupportedUnmanagedHeadings
        if ($blockResult.Exists) {
            $actualInstalledTools.Add($toolName)
        }
        $adapterResults.Add([pscustomobject]@{
            Tool = $toolName
            Path = $configPath
            Info = $configInfo
            Block = $blockResult
        })
    }

    $currentReceiptBytes = New-ReceiptBytes -Manifest $Manifest -PolicyHash ([string] $Manifest.policy.sha256) -HelperHash ([string] $Manifest.helper.sha256) -InstalledTools @($actualInstalledTools)
    $currentReceiptHash = Get-Sha256Hex -Bytes $currentReceiptBytes
    if (-not [string]::Equals([string] $receiptState.Sha256, $currentReceiptHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation receipt is modified or inconsistent with the installed managed blocks.'
    }

    $remainingTools = @($actualInstalledTools | Where-Object { $SelectedTools -notcontains $_ })
    if ($RemoveShared -and $remainingTools.Count -gt 0) {
        throw ('Shared files cannot be removed while managed blocks remain: ' + ($remainingTools -join ', '))
    }

    $operations = [Collections.Generic.List[object]]::new()
    $actions = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($adapterResult in $adapterResults) {
        if ($SelectedTools -notcontains $adapterResult.Tool -or -not $adapterResult.Block.Exists) {
            continue
        }
        $desiredBytes = Convert-TextToBytes -Text $adapterResult.Block.Desired -HasUtf8Bom $adapterResult.Info.HasUtf8Bom
        $before = Get-PathState -LiteralPath $adapterResult.Path
        $afterHash = Get-Sha256Hex -Bytes $desiredBytes
        $operations.Add([pscustomobject][ordered]@{
            Index = $index
            Kind = 'Adapter'
            Tool = $adapterResult.Tool
            Path = $adapterResult.Path
            Action = 'RemoveManagedBlock'
            BeforeExists = $true
            BeforeSha256 = $before.Sha256
            BeforeLength = $before.Length
            AfterExists = $true
            AfterSha256 = $afterHash
            AfterLength = [long] $desiredBytes.Length
        })
        $actions.Add([pscustomobject]@{ Index = $index; Type = 'Write'; Path = $adapterResult.Path; Bytes = $desiredBytes; Before = $before })
        $index++
    }

    if ($RemoveShared) {
        foreach ($sharedDefinition in @(
            [pscustomobject]@{ Kind = 'Policy'; Path = $policyTarget; State = $policyState },
            [pscustomobject]@{ Kind = 'Helper'; Path = $helperTarget; State = $helperState },
            [pscustomobject]@{ Kind = 'Receipt'; Path = $receiptTarget; State = $receiptState }
        )) {
            $operations.Add([pscustomobject][ordered]@{
                Index = $index
                Kind = $sharedDefinition.Kind
                Tool = $null
                Path = $sharedDefinition.Path
                Action = 'MoveToBackup'
                BeforeExists = $true
                BeforeSha256 = $sharedDefinition.State.Sha256
                BeforeLength = $sharedDefinition.State.Length
                AfterExists = $false
                AfterSha256 = $null
                AfterLength = [long] 0
            })
            $actions.Add([pscustomobject]@{ Index = $index; Type = 'Move'; Path = $sharedDefinition.Path; Before = $sharedDefinition.State })
            $index++
        }
    } else {
        $desiredReceiptBytes = New-ReceiptBytes -Manifest $Manifest -PolicyHash ([string] $Manifest.policy.sha256) -HelperHash ([string] $Manifest.helper.sha256) -InstalledTools $remainingTools
        $desiredReceiptHash = Get-Sha256Hex -Bytes $desiredReceiptBytes
        $receiptChanged = -not [string]::Equals([string] $receiptState.Sha256, $desiredReceiptHash, [StringComparison]::OrdinalIgnoreCase)
        $operations.Add([pscustomobject][ordered]@{
            Index = $index
            Kind = 'Receipt'
            Tool = $null
            Path = $receiptTarget
            Action = if ($receiptChanged) { 'Update' } else { 'Unchanged' }
            BeforeExists = $true
            BeforeSha256 = $receiptState.Sha256
            BeforeLength = $receiptState.Length
            AfterExists = $true
            AfterSha256 = $desiredReceiptHash
            AfterLength = [long] $desiredReceiptBytes.Length
        })
        if ($receiptChanged) {
            $actions.Add([pscustomobject]@{ Index = $index; Type = 'Write'; Path = $receiptTarget; Bytes = $desiredReceiptBytes; Before = $receiptState })
        }
    }

    $backupParent = Resolve-ChildPath -Root $ProfileRoot -RelativePath '.file-deletion-safety-rules-backups' -Label 'backup directory'
    $publicPlan = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Operation = 'Uninstall'
        PackageName = [string] $Manifest.name
        PackageVersion = [string] $Manifest.version
        UserProfileRoot = $ProfileRoot
        SelectedTools = @($SelectedTools)
        RemoveSharedFiles = $RemoveShared
        BackupParent = $backupParent
        Operations = @($operations)
    }
    $planBytes = [Text.UTF8Encoding]::new($false).GetBytes(($publicPlan | ConvertTo-Json -Depth 12 -Compress))
    return [pscustomobject]@{ Plan = $publicPlan; PlanSha256 = Get-Sha256Hex -Bytes $planBytes; Actions = @($actions) }
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $TransactionRoot,
        [Parameter(Mandatory)][string] $AllowedRoot
    )

    Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $Destination -Label 'transaction destination'
    Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $TransactionRoot -Label 'transaction backup'
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $Destination -Label 'transaction destination'
    $temp = Join-Path $parent ('.file-deletion-safety-rules-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllBytes($temp, $Bytes)
    try {
        Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $Destination -Label 'transaction destination'
        if ([IO.File]::Exists($Destination)) {
            $replaceBackup = Join-Path $TransactionRoot ('replace-before-' + [guid]::NewGuid().ToString('N') + '.bin')
            [IO.File]::Replace($temp, $Destination, $replaceBackup, $true)
        } else {
            [IO.File]::Move($temp, $Destination)
        }
    } finally {
        if ([IO.File]::Exists($temp)) {
            Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $TransactionRoot -Label 'transaction backup'
            [IO.File]::Move($temp, (Join-Path $TransactionRoot ('abandoned-' + [guid]::NewGuid().ToString('N') + '.tmp')))
        }
    }
}

function Invoke-UninstallTransaction {
    param([Parameter(Mandatory)][psobject] $PlanResult)

    foreach ($action in $PlanResult.Actions) {
        Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $action.Path -Label 'transaction target'
        if (-not (Test-StateMatches -Expected $action.Before -Actual (Get-PathState -LiteralPath $action.Path))) {
            throw "PLAN_DRIFT: target changed before the transaction: $($action.Path)"
        }
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $transactionRoot = Join-Path $PlanResult.Plan.BackupParent $stamp
    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $transactionRoot -Label 'transaction backup'
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $transactionRoot -Label 'transaction backup'
    [IO.File]::WriteAllText((Join-Path $transactionRoot 'plan.json'), ($PlanResult.Plan | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

    $applied = [Collections.Generic.List[object]]::new()
    try {
        foreach ($action in $PlanResult.Actions) {
            Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $action.Path -Label 'transaction target'
            if (-not (Test-StateMatches -Expected $action.Before -Actual (Get-PathState -LiteralPath $action.Path))) {
                throw "PLAN_DRIFT: target changed during the transaction: $($action.Path)"
            }

            if ($action.Type -eq 'Write') {
                $backupPath = Join-Path $transactionRoot ('before-' + $action.Index.ToString('D4') + '.bin')
                [IO.File]::Copy($action.Path, $backupPath, $false)
                $backupState = Get-PathState -LiteralPath $backupPath
                if (-not (Test-StateMatches -Expected $action.Before -Actual $backupState)) {
                    throw "Backup verification failed: $($action.Path)"
                }
                $applied.Add([pscustomobject]@{ Action = $action; BackupPath = $backupPath })
                Write-AtomicBytes -Bytes $action.Bytes -Destination $action.Path -TransactionRoot $transactionRoot -AllowedRoot $PlanResult.Plan.UserProfileRoot
                $expectedHash = Get-Sha256Hex -Bytes $action.Bytes
                $after = Get-PathState -LiteralPath $action.Path
                if (-not [string]::Equals([string] $after.Sha256, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Post-write verification failed: $($action.Path)"
                }
            } else {
                $backupPath = Join-Path $transactionRoot ('removed-' + $action.Index.ToString('D4') + '-' + [IO.Path]::GetFileName($action.Path))
                $applied.Add([pscustomobject]@{ Action = $action; BackupPath = $backupPath })
                [IO.File]::Move($action.Path, $backupPath)
                $movedState = Get-PathState -LiteralPath $backupPath
                if ((Test-Path -LiteralPath $action.Path) -or -not (Test-StateMatches -Expected $action.Before -Actual $movedState)) {
                    throw "Move verification failed: $($action.Path)"
                }
            }
        }
        return [pscustomobject]@{ Status = 'APPLIED'; BackupRoot = $transactionRoot; OperationError = $null; RollbackFailures = @() }
    } catch {
        $operationError = $_.Exception.Message
        $rollbackFailures = [Collections.Generic.List[string]]::new()
        for ($appliedIndex = $applied.Count - 1; $appliedIndex -ge 0; $appliedIndex--) {
            $entry = $applied[$appliedIndex]
            try {
                Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $entry.Action.Path -Label 'rollback target'
                $currentState = Get-PathState -LiteralPath $entry.Action.Path
                if (Test-StateMatches -Expected $entry.Action.Before -Actual $currentState) {
                    continue
                }
                if ($entry.Action.Type -eq 'Write') {
                    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $entry.BackupPath -Label 'rollback backup'
                    Write-AtomicBytes -Bytes ([IO.File]::ReadAllBytes($entry.BackupPath)) -Destination $entry.Action.Path -TransactionRoot $transactionRoot -AllowedRoot $PlanResult.Plan.UserProfileRoot
                } else {
                    if (Test-Path -LiteralPath $entry.Action.Path) {
                        throw 'The original path was unexpectedly recreated.'
                    }
                    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $entry.BackupPath -Label 'rollback backup'
                    [IO.File]::Move($entry.BackupPath, $entry.Action.Path)
                }
            } catch {
                $rollbackFailures.Add("$($entry.Action.Path): $($_.Exception.Message)")
            }
        }
        foreach ($action in $PlanResult.Actions) {
            try {
                Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $action.Path -Label 'rollback verification'
                if (-not (Test-StateMatches -Expected $action.Before -Actual (Get-PathState -LiteralPath $action.Path))) {
                    $rollbackFailures.Add("$($action.Path): restored state does not match Preview")
                }
            } catch {
                $rollbackFailures.Add("$($action.Path): $($_.Exception.Message)")
            }
        }
        return [pscustomobject]@{
            Status = if ($rollbackFailures.Count -eq 0) { 'ROLLED_BACK' } else { 'ROLLBACK_FAILED' }
            BackupRoot = $transactionRoot
            OperationError = $operationError
            RollbackFailures = @($rollbackFailures)
        }
    }
}

try {
    $profileRoot = Get-NormalizedProfileRoot -Path $UserProfileRoot
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding utf8 | ConvertFrom-Json -Depth 20
    Assert-ManifestContract -PackageRoot $packageRoot -Manifest $manifest
    $selectedTools = Get-SelectedTools -Requested $Tool
    $planResult = New-UninstallPlan -ProfileRoot $profileRoot -SelectedTools $selectedTools -PackageRoot $packageRoot -Manifest $manifest -RemoveShared ([bool] $RemoveSharedFiles)

    if ($Mode -eq 'Preview') {
        [pscustomobject]@{ Mode = 'Preview'; Status = 'PREVIEW'; PlanSha256 = $planResult.PlanSha256; Plan = $planResult.Plan } | ConvertTo-Json -Depth 14
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedPlanSha256) -or $ExpectedPlanSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        [pscustomobject]@{ Mode = 'Apply'; Status = 'PLAN_REQUIRED'; Message = 'Apply requires the exact PlanSha256 returned by Preview.' } | ConvertTo-Json -Depth 5
        exit 2
    }
    if (-not [string]::Equals($ExpectedPlanSha256, $planResult.PlanSha256, [StringComparison]::OrdinalIgnoreCase)) {
        [pscustomobject]@{
            Mode = 'Apply'
            Status = 'PLAN_MISMATCH'
            ExpectedPlanSha256 = $ExpectedPlanSha256.ToUpperInvariant()
            ActualPlanSha256 = $planResult.PlanSha256
            Message = 'The uninstall state changed after Preview; no files were changed.'
        } | ConvertTo-Json -Depth 5
        exit 2
    }
    if ($planResult.Actions.Count -eq 0) {
        [pscustomobject]@{ Mode = 'Apply'; Status = 'APPLIED'; PlanSha256 = $planResult.PlanSha256; BackupRoot = $null; Plan = $planResult.Plan } | ConvertTo-Json -Depth 14
        exit 0
    }

    $transaction = Invoke-UninstallTransaction -PlanResult $planResult
    [pscustomobject]@{
        Mode = 'Apply'
        Status = $transaction.Status
        PlanSha256 = $planResult.PlanSha256
        BackupRoot = $transaction.BackupRoot
        OperationError = $transaction.OperationError
        RollbackFailures = @($transaction.RollbackFailures)
        Plan = $planResult.Plan
    } | ConvertTo-Json -Depth 14
    if ($transaction.Status -eq 'APPLIED') { exit 0 }
    if ($transaction.Status -eq 'ROLLED_BACK') { exit 2 }
    exit 3
} catch {
    [pscustomobject]@{ Mode = $Mode; Status = 'FAILED'; Message = $_.Exception.Message } | ConvertTo-Json -Depth 5
    exit 1
}
