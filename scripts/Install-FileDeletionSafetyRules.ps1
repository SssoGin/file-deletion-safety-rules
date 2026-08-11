[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')]
    [string] $Mode = 'Preview',

    [ValidateSet('All', 'Codex', 'Claude', 'OpenCode')]
    [string[]] $Tool = @('All'),

    [string] $UserProfileRoot = [Environment]::GetFolderPath('UserProfile'),

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
        if ([string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
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

function Get-LegacyUnmanagedBlockState {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][string] $PolicyTarget,
        [Parameter(Mandatory)][psobject] $Manifest
    )

    $pattern = '(?ms)^## 0\.1 文件安全删除规则会话开关[ \t]*\r?\n.*?(?=^#{1,2}[ \t]+|\z)'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -eq 0) {
        return $null
    }
    if ($matches.Count -ne 1) {
        throw 'The legacy unmanaged deletion-safety block is duplicated or ambiguous.'
    }

    $rawBlock = $matches[0].Value
    $canonical = ($rawBlock -replace "`r`n", "`n").TrimEnd([char[]]@("`r", "`n"))
    $policyPattern = [regex]::Escape($PolicyTarget)
    if (-not [regex]::IsMatch($canonical, $policyPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        throw 'The legacy unmanaged deletion-safety block does not reference the expected policy path.'
    }
    $canonical = [regex]::Replace(
        $canonical,
        $policyPattern,
        '{{POLICY_PATH}}',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $canonicalHash = Get-Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    $declaredHashes = @(Get-LegacyReceiptlessInstallations -Manifest $Manifest | ForEach-Object { $_.UnmanagedAdapterSha256 })
    if (@($declaredHashes | Where-Object { [string]::Equals([string] $_, $canonicalHash, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        throw 'The legacy unmanaged deletion-safety block does not match an exact supported legacy adapter.'
    }

    return [pscustomobject]@{
        Sha256 = $canonicalHash
        Start = [int] $matches[0].Index
        Length = [int] $matches[0].Length
    }
}

function Remove-LegacyUnmanagedBlock {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][psobject] $LegacyBlockState
    )

    return $Text.Remove([int] $LegacyBlockState.Start, [int] $LegacyBlockState.Length)
}

function Get-LegacyReceiptlessInstallations {
    param([Parameter(Mandatory)][psobject] $Manifest)

    $property = $Manifest.PSObject.Properties['legacyReceiptlessInstallations']
    if ($null -eq $property) {
        throw 'Manifest legacyReceiptlessInstallations is missing.'
    }

    $entries = @($property.Value)
    if ($entries.Count -eq 0) {
        throw 'Manifest legacyReceiptlessInstallations must not be empty.'
    }

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
        $validated.Add([pscustomobject]@{
            Version = $version
            PolicySha256 = $policySha256.ToUpperInvariant()
            HelperSha256 = $helperSha256.ToUpperInvariant()
            UnmanagedAdapterSha256 = $unmanagedAdapterSha256.ToUpperInvariant()
        })
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
    $requiredUnsupportedHeadings = @(
        '## 0.1 删除保护',
        '## 0.1 文件安全删除规则会话开关',
        '## 文件安全删除规则会话开关'
    )
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
        return [pscustomobject]@{
            Exists = $false
            Bytes = [byte[]]::new(0)
            Text = ''
            HasUtf8Bom = $true
        }
    }
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Expected a regular file: $LiteralPath"
    }

    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{
        Exists = $true
        Bytes = $bytes
        Text = $text
        HasUtf8Bom = $hasBom
    }
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
    return [pscustomobject]@{
        Exists = $true
        Sha256 = Get-Sha256Hex -Bytes $bytes
        Length = [long] $bytes.Length
    }
}

function Test-StateMatches {
    param(
        [Parameter(Mandatory)][psobject] $Expected,
        [Parameter(Mandatory)][psobject] $Actual
    )

    if ([bool] $Expected.Exists -ne [bool] $Actual.Exists) {
        return $false
    }
    if (-not [bool] $Expected.Exists) {
        return $true
    }
    return [string]::Equals([string] $Expected.Sha256, [string] $Actual.Sha256, [StringComparison]::OrdinalIgnoreCase) -and
        [long] $Expected.Length -eq [long] $Actual.Length
}

function Test-OrdinalStringSetEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($value in $Left) {
        if ($Right -cnotcontains $value) { return $false }
    }
    return $true
}

function Get-ValidatedReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][psobject] $PolicyState,
        [Parameter(Mandatory)][psobject] $HelperState,
        [Parameter(Mandatory)][psobject] $Manifest
    )

    $receiptInfo = Get-StrictTextInfo -LiteralPath $ReceiptPath
    $requiredProperties = @('SchemaVersion', 'PackageName', 'PackageVersion', 'PolicySha256', 'HelperSha256', 'InstalledTools')
    $jsonDocument = $null
    try {
        $jsonDocument = [Text.Json.JsonDocument]::Parse($receiptInfo.Text)
        if ($jsonDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'The root value must be an object.'
        }
        $jsonProperties = @($jsonDocument.RootElement.EnumerateObject())
        if ($jsonProperties.Count -ne $requiredProperties.Count) {
            throw 'The object must contain exactly the supported properties.'
        }
        $seenProperties = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $jsonProperties) {
            if (-not $seenProperties.Add($property.Name)) {
                throw "Duplicate property: $($property.Name)"
            }
            if ($requiredProperties -cnotcontains $property.Name) {
                throw "Unsupported property: $($property.Name)"
            }
            if ([string]::Equals($property.Name, 'SchemaVersion', [StringComparison]::Ordinal)) {
                if ($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Number) {
                    throw 'SchemaVersion must be an integer.'
                }
                try { [void] $property.Value.GetInt32() } catch { throw 'SchemaVersion must be a 32-bit integer.' }
            } elseif ([string]::Equals($property.Name, 'InstalledTools', [StringComparison]::Ordinal)) {
                if ($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
                    throw 'InstalledTools must be an array.'
                }
                foreach ($toolElement in @($property.Value.EnumerateArray())) {
                    if ($toolElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
                        throw 'Every InstalledTools entry must be a string.'
                    }
                }
            } elseif ($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw "$($property.Name) must be a string."
            }
        }
    } catch {
        throw "The installation receipt is not valid strict JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }
    try {
        $receipt = $receiptInfo.Text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        throw 'The installation receipt could not be converted from validated JSON.'
    }
    if ($null -eq $receipt -or $receipt -is [Array]) {
        throw 'The installation receipt must be one JSON object.'
    }

    $receiptProperties = @($receipt.PSObject.Properties)
    if ($receiptProperties.Count -ne $requiredProperties.Count) {
        throw 'The installation receipt has an unsupported schema.'
    }
    foreach ($property in $receiptProperties) {
        if ($requiredProperties -cnotcontains [string] $property.Name) {
            throw "The installation receipt contains an unsupported property: $($property.Name)"
        }
    }
    foreach ($propertyName in $requiredProperties) {
        if (@($receiptProperties | Where-Object { [string]::Equals([string] $_.Name, $propertyName, [StringComparison]::Ordinal) }).Count -ne 1) {
            throw "The installation receipt is missing a required property: $propertyName"
        }
    }

    if ([int] $receipt.SchemaVersion -ne 1 -or
        -not [string]::Equals([string] $receipt.PackageName, [string] $Manifest.name, [StringComparison]::Ordinal) -or
        [string] $receipt.PackageVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$' -or
        [string] $receipt.PolicySha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string] $receipt.HelperSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The installation receipt identity or hashes are invalid.'
    }
    if (-not [string]::Equals([string] $PolicyState.Sha256, [string] $receipt.PolicySha256, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string] $HelperState.Sha256, [string] $receipt.HelperSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installed policy or helper no longer matches its ownership receipt.'
    }

    $installedToolsProperty = @($receiptProperties | Where-Object { [string]::Equals([string] $_.Name, 'InstalledTools', [StringComparison]::Ordinal) })[0]
    if ($installedToolsProperty.Value -isnot [Array]) {
        throw 'The installation receipt InstalledTools value must be an array.'
    }
    $installedTools = @($installedToolsProperty.Value | ForEach-Object { [string] $_ })
    $validatedTools = [Collections.Generic.List[string]]::new()
    foreach ($toolName in $installedTools) {
        if (@('Codex', 'Claude', 'OpenCode') -cnotcontains $toolName -or $validatedTools.Contains($toolName)) {
            throw 'The installation receipt contains an invalid or duplicate tool.'
        }
        $validatedTools.Add($toolName)
    }

    return [pscustomobject]@{
        Receipt = $receipt
        InstalledTools = @($validatedTools)
    }
}

function Get-AdapterInstallStates {
    param(
        [Parameter(Mandatory)][string] $ProfileRoot,
        [Parameter(Mandatory)][string] $PackageRoot,
        [Parameter(Mandatory)][string] $PolicyTarget,
        [Parameter(Mandatory)][psobject] $Manifest
    )

    $states = [Collections.Generic.List[object]]::new()
    $beginMarker = [string] $Manifest.managedMarkers.begin
    $endMarker = [string] $Manifest.managedMarkers.end
    $unsupportedHeadings = @(Get-UnsupportedUnmanagedHeadings -Manifest $Manifest)
    foreach ($toolName in @('Codex', 'Claude', 'OpenCode')) {
        $toolSpec = $Manifest.tools.$toolName
        $configPath = Resolve-ChildPath -Root $ProfileRoot -RelativePath ([string] $toolSpec.config) -Label "$toolName.config"
        $configInfo = Get-StrictTextInfo -LiteralPath $configPath
        $configState = if ($configInfo.Exists) {
            [pscustomobject]@{ Exists = $true; Sha256 = Get-Sha256Hex -Bytes $configInfo.Bytes; Length = [long] $configInfo.Bytes.Length }
        } else {
            [pscustomobject]@{ Exists = $false; Sha256 = $null; Length = [long] 0 }
        }

        $beginCount = ([regex]::Matches($configInfo.Text, [regex]::Escape($beginMarker))).Count
        $endCount = ([regex]::Matches($configInfo.Text, [regex]::Escape($endMarker))).Count
        if ($beginCount -ne $endCount -or $beginCount -gt 1) {
            throw "The existing $toolName managed block markers are missing, duplicated, or unbalanced."
        }

        $hasManagedBlock = $beginCount -eq 1
        $legacyUnmanagedBlockState = $null
        if ($hasManagedBlock) {
            if (Test-ContainsUnsupportedUnmanagedHeading -Text $configInfo.Text -Headings $unsupportedHeadings -BeginMarker $beginMarker -EndMarker $endMarker) {
                throw "Unsupported unmanaged and managed deletion-safety rules coexist in $toolName."
            }
            $adapterPath = Resolve-ChildPath -Root $PackageRoot -RelativePath ([string] $toolSpec.adapter) -Label "$toolName.adapter"
            $adapterInfo = Get-StrictTextInfo -LiteralPath $adapterPath
            $newline = if ($configInfo.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
            $expectedBlock = ($adapterInfo.Text.Replace('{{POLICY_PATH}}', $PolicyTarget) -replace "`r?`n", $newline).TrimEnd([char[]]@("`r", "`n"))
            $pattern = '(?ms)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
            $matches = [regex]::Matches($configInfo.Text, $pattern)
            if ($matches.Count -ne 1 -or
                -not [string]::Equals($matches[0].Value, $expectedBlock, [StringComparison]::Ordinal) -or
                $configInfo.Text.Contains('{{POLICY_PATH}}')) {
                throw "The existing $toolName managed block differs from this package; refusing to overwrite user-modified content."
            }
        } elseif (Test-ContainsUnsupportedUnmanagedHeading -Text $configInfo.Text -Headings $unsupportedHeadings) {
            $legacyUnmanagedBlockState = Get-LegacyUnmanagedBlockState -Text $configInfo.Text -PolicyTarget $PolicyTarget -Manifest $Manifest
            if ($null -eq $legacyUnmanagedBlockState) {
                throw "Unsupported unmanaged deletion-safety rules were found in $toolName."
            }
        }

        $states.Add([pscustomobject]@{
            Tool = $toolName
            ConfigPath = $configPath
            Info = $configInfo
            State = $configState
            HasManagedBlock = $hasManagedBlock
            LegacyUnmanagedBlockState = $legacyUnmanagedBlockState
        })
    }
    return @($states)
}

function Get-DesiredConfigText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Current,
        [Parameter(Mandatory)][string] $ManagedBlock,
        [Parameter(Mandatory)][string] $BeginMarker,
        [Parameter(Mandatory)][string] $EndMarker,
        [Parameter(Mandatory)][string[]] $UnsupportedUnmanagedHeadings
    )

    $beginCount = ([regex]::Matches($Current, [regex]::Escape($BeginMarker))).Count
    $endCount = ([regex]::Matches($Current, [regex]::Escape($EndMarker))).Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) {
        throw 'Managed block markers are missing, duplicated, or unbalanced.'
    }

    if (Test-ContainsUnsupportedUnmanagedHeading -Text $Current -Headings $UnsupportedUnmanagedHeadings -BeginMarker $BeginMarker -EndMarker $EndMarker) {
        throw 'Unsupported unmanaged deletion-safety rules were found; refusing to modify the config.'
    }

    $newline = if ($Current.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = ($ManagedBlock -replace "`r?`n", $newline).TrimEnd([char[]]@("`r", "`n"))
    if ($beginCount -eq 1) {
        $pattern = '(?ms)' + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker)
        $matches = [regex]::Matches($Current, $pattern)
        if ($matches.Count -ne 1) {
            throw 'Managed block markers could not be paired safely.'
        }
        return [regex]::Replace($Current, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $block }, 1)
    }
    if ([string]::IsNullOrWhiteSpace($Current)) {
        return $block + $newline
    }
    return $Current.TrimEnd([char[]]@("`r", "`n")) + $newline + $newline + $block + $newline
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

function New-InstallPlan {
    param(
        [Parameter(Mandatory)][string] $ProfileRoot,
        [Parameter(Mandatory)][string[]] $SelectedTools,
        [Parameter(Mandatory)][string] $PackageRoot,
        [Parameter(Mandatory)][psobject] $Manifest
    )

    $sharedRoot = Resolve-ChildPath -Root $ProfileRoot -RelativePath ([string] $Manifest.sharedInstallDirectory) -Label 'sharedInstallDirectory'
    $policySource = Resolve-ChildPath -Root $PackageRoot -RelativePath ([string] $Manifest.policy.source) -Label 'policy.source'
    $helperSource = Resolve-ChildPath -Root $PackageRoot -RelativePath ([string] $Manifest.helper.source) -Label 'helper.source'
    if (-not (Test-Path -LiteralPath $policySource -PathType Leaf) -or -not (Test-Path -LiteralPath $helperSource -PathType Leaf)) {
        throw 'Package policy or helper source is missing.'
    }

    $policyBytes = [IO.File]::ReadAllBytes($policySource)
    $helperBytes = [IO.File]::ReadAllBytes($helperSource)
    $policyHash = Get-Sha256Hex -Bytes $policyBytes
    $helperHash = Get-Sha256Hex -Bytes $helperBytes
    if (-not [string]::Equals($policyHash, [string] $Manifest.policy.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package policy hash mismatch: $policyHash"
    }
    if (-not [string]::Equals($helperHash, [string] $Manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package helper hash mismatch: $helperHash"
    }

    $policyTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $Manifest.policy.installedName) -Label 'policy.installedName'
    $helperTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $Manifest.helper.installedName) -Label 'helper.installedName'
    $receiptTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $Manifest.receipt.installedName) -Label 'receipt.installedName'
    $policyState = Get-PathState -LiteralPath $policyTarget
    $helperState = Get-PathState -LiteralPath $helperTarget
    $receiptState = Get-PathState -LiteralPath $receiptTarget
    $sharedStates = @($policyState, $helperState, $receiptState)
    $sharedExistingCount = @($sharedStates | Where-Object { $_.Exists }).Count
    $isLegacyReceiptlessState = $policyState.Exists -and $helperState.Exists -and -not $receiptState.Exists
    if ($sharedExistingCount -ne 0 -and $sharedExistingCount -ne 3 -and -not $isLegacyReceiptlessState) {
        throw 'The policy, helper, and installation receipt must either all be absent or all exist.'
    }

    $adapterStates = @(Get-AdapterInstallStates -ProfileRoot $ProfileRoot -PackageRoot $PackageRoot -PolicyTarget $policyTarget -Manifest $Manifest)
    $managedTools = @($adapterStates | Where-Object { $_.HasManagedBlock } | ForEach-Object { [string] $_.Tool })
    $legacyUnmanagedTools = @($adapterStates | Where-Object { $null -ne $_.LegacyUnmanagedBlockState } | ForEach-Object { [string] $_.Tool })
    $installedTools = [Collections.Generic.List[string]]::new()
    if ($sharedExistingCount -eq 0) {
        if ($managedTools.Count -ne 0 -or $legacyUnmanagedTools.Count -ne 0) {
            throw 'A deletion-safety block exists without shared files and an ownership receipt.'
        }
    } elseif ($isLegacyReceiptlessState) {
        $legacyMatches = @(Get-LegacyReceiptlessInstallations -Manifest $Manifest | Where-Object {
            [string]::Equals([string] $_.PolicySha256, [string] $policyState.Sha256, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string] $_.HelperSha256, [string] $helperState.Sha256, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($legacyMatches.Count -ne 1) {
            throw 'Receiptless shared files do not match an exact supported legacy installation.'
        }
        $matchingLegacyUnmanagedTools = @($adapterStates | Where-Object {
            $null -ne $_.LegacyUnmanagedBlockState -and
            [string]::Equals([string] $_.LegacyUnmanagedBlockState.Sha256, [string] $legacyMatches[0].UnmanagedAdapterSha256, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { [string] $_.Tool })
        if ($managedTools.Count + $matchingLegacyUnmanagedTools.Count -eq 0) {
            throw 'Receiptless legacy shared files have no exact package-managed or supported unmanaged tool block; ownership cannot be proven.'
        }
        foreach ($toolName in $matchingLegacyUnmanagedTools) {
            if ($SelectedTools -cnotcontains $toolName) {
                throw "The legacy unmanaged $toolName block must be selected for migration."
            }
        }
        foreach ($toolName in @($managedTools + $matchingLegacyUnmanagedTools)) {
            $installedTools.Add([string] $toolName)
        }
    } else {
        $validatedReceipt = Get-ValidatedReceipt -ReceiptPath $receiptTarget -PolicyState $policyState -HelperState $helperState -Manifest $Manifest
        if (-not (Test-OrdinalStringSetEqual -Left @($validatedReceipt.InstalledTools) -Right $managedTools)) {
            throw 'The installation receipt tool set does not match the managed blocks on disk.'
        }
        foreach ($toolName in @($validatedReceipt.InstalledTools)) {
            $installedTools.Add([string] $toolName)
        }
    }

    $operations = [Collections.Generic.List[object]]::new()
    $writes = [Collections.Generic.List[object]]::new()
    $index = 0
    $sharedDefinitions = @(
        [pscustomobject]@{ Kind = 'Policy'; Bytes = $policyBytes; Target = $policyTarget; Before = $policyState },
        [pscustomobject]@{ Kind = 'Helper'; Bytes = $helperBytes; Target = $helperTarget; Before = $helperState }
    )
    foreach ($definition in $sharedDefinitions) {
        $before = $definition.Before
        $afterHash = Get-Sha256Hex -Bytes $definition.Bytes
        $changed = -not $before.Exists -or -not [string]::Equals([string] $before.Sha256, $afterHash, [StringComparison]::OrdinalIgnoreCase)
        $action = if (-not $changed) { 'Unchanged' } elseif ($before.Exists) { 'Update' } else { 'Create' }
        $operations.Add([pscustomobject][ordered]@{
            Index = $index
            Kind = $definition.Kind
            Tool = $null
            Path = $definition.Target
            Action = $action
            BeforeExists = [bool] $before.Exists
            BeforeSha256 = $before.Sha256
            BeforeLength = [long] $before.Length
            AfterSha256 = $afterHash
            AfterLength = [long] $definition.Bytes.Length
            ProposedManagedBlock = $null
        })
        if ($changed) {
            $writes.Add([pscustomobject]@{ Index = $index; Path = $definition.Target; Bytes = $definition.Bytes; Before = $before })
        }
        $index++
    }

    $beginMarker = [string] $Manifest.managedMarkers.begin
    $endMarker = [string] $Manifest.managedMarkers.end
    $unsupportedUnmanagedHeadings = @(Get-UnsupportedUnmanagedHeadings -Manifest $Manifest)
    foreach ($toolName in $SelectedTools) {
        $toolSpec = $Manifest.tools.$toolName
        $adapterState = @($adapterStates | Where-Object { [string]::Equals([string] $_.Tool, $toolName, [StringComparison]::Ordinal) })[0]
        $configPath = $adapterState.ConfigPath
        $adapterPath = Resolve-ChildPath -Root $PackageRoot -RelativePath ([string] $toolSpec.adapter) -Label "$toolName.adapter"
        if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
            throw "Package adapter is missing: $adapterPath"
        }
        $adapterInfo = Get-StrictTextInfo -LiteralPath $adapterPath
        $managedBlock = $adapterInfo.Text.Replace('{{POLICY_PATH}}', $policyTarget)
        $currentInfo = $adapterState.Info
        $currentText = if ($null -ne $adapterState.LegacyUnmanagedBlockState) {
            Remove-LegacyUnmanagedBlock -Text $currentInfo.Text -LegacyBlockState $adapterState.LegacyUnmanagedBlockState
        } else {
            $currentInfo.Text
        }
        $desiredText = Get-DesiredConfigText -Current $currentText -ManagedBlock $managedBlock -BeginMarker $beginMarker -EndMarker $endMarker -UnsupportedUnmanagedHeadings $unsupportedUnmanagedHeadings
        $desiredBytes = Convert-TextToBytes -Text $desiredText -HasUtf8Bom $currentInfo.HasUtf8Bom
        $before = $adapterState.State
        $afterHash = Get-Sha256Hex -Bytes $desiredBytes
        $changed = -not $before.Exists -or -not [string]::Equals([string] $before.Sha256, $afterHash, [StringComparison]::OrdinalIgnoreCase)
        $action = if (-not $changed) { 'Unchanged' } elseif ($before.Exists) { 'Update' } else { 'Create' }
        $operations.Add([pscustomobject][ordered]@{
            Index = $index
            Kind = 'Adapter'
            Tool = $toolName
            Path = $configPath
            Action = $action
            BeforeExists = [bool] $before.Exists
            BeforeSha256 = $before.Sha256
            BeforeLength = [long] $before.Length
            AfterSha256 = $afterHash
            AfterLength = [long] $desiredBytes.Length
            ProposedManagedBlock = $managedBlock.TrimEnd()
        })
        if ($changed) {
            $writes.Add([pscustomobject]@{ Index = $index; Path = $configPath; Bytes = $desiredBytes; Before = $before })
        }
        $index++
    }

    foreach ($toolName in $SelectedTools) {
        if (-not $installedTools.Contains($toolName)) {
            $installedTools.Add($toolName)
        }
    }

    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 1
        PackageName = [string] $Manifest.name
        PackageVersion = [string] $Manifest.version
        PolicySha256 = $policyHash
        HelperSha256 = $helperHash
        InstalledTools = @($installedTools)
    }
    $receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 8) + "`n")
    $receiptBefore = $receiptState
    $receiptAfterHash = Get-Sha256Hex -Bytes $receiptBytes
    $receiptChanged = -not $receiptBefore.Exists -or -not [string]::Equals([string] $receiptBefore.Sha256, $receiptAfterHash, [StringComparison]::OrdinalIgnoreCase)
    $operations.Add([pscustomobject][ordered]@{
        Index = $index
        Kind = 'Receipt'
        Tool = $null
        Path = $receiptTarget
        Action = if (-not $receiptChanged) { 'Unchanged' } elseif ($receiptBefore.Exists) { 'Update' } else { 'Create' }
        BeforeExists = [bool] $receiptBefore.Exists
        BeforeSha256 = $receiptBefore.Sha256
        BeforeLength = [long] $receiptBefore.Length
        AfterSha256 = $receiptAfterHash
        AfterLength = [long] $receiptBytes.Length
        ProposedManagedBlock = $null
    })
    if ($receiptChanged) {
        $writes.Add([pscustomobject]@{ Index = $index; Path = $receiptTarget; Bytes = $receiptBytes; Before = $receiptBefore })
    }

    $backupParent = Resolve-ChildPath -Root $ProfileRoot -RelativePath '.file-deletion-safety-rules-backups' -Label 'backup directory'
    $publicPlan = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Operation = 'Install'
        PackageName = [string] $Manifest.name
        PackageVersion = [string] $Manifest.version
        UserProfileRoot = $ProfileRoot
        SelectedTools = @($SelectedTools)
        BackupParent = $backupParent
        Operations = @($operations)
    }
    $planBytes = [Text.UTF8Encoding]::new($false).GetBytes(($publicPlan | ConvertTo-Json -Depth 12 -Compress))
    return [pscustomobject]@{
        Plan = $publicPlan
        PlanSha256 = Get-Sha256Hex -Bytes $planBytes
        Writes = @($writes)
    }
}

function New-RequiredDirectories {
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]] $CreatedDirectories
    )

    $missing = [Collections.Generic.List[string]]::new()
    $cursor = $DirectoryPath
    while (-not (Test-Path -LiteralPath $cursor)) {
        $missing.Add($cursor)
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or [string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $parent
    }
    for ($missingIndex = $missing.Count - 1; $missingIndex -ge 0; $missingIndex--) {
        [IO.Directory]::CreateDirectory($missing[$missingIndex]) | Out-Null
        $CreatedDirectories.Add($missing[$missingIndex])
    }
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $TransactionRoot,
        [Parameter(Mandatory)][string] $AllowedRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]] $CreatedDirectories
    )

    Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $Destination -Label 'transaction destination'
    Assert-NoReparseTraversal -Root $AllowedRoot -LiteralPath $TransactionRoot -Label 'transaction backup'
    $parent = Split-Path -Parent $Destination
    New-RequiredDirectories -DirectoryPath $parent -CreatedDirectories $CreatedDirectories
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
            $abandoned = Join-Path $TransactionRoot ('abandoned-' + [guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::Move($temp, $abandoned)
        }
    }
}

function Invoke-InstallTransaction {
    param([Parameter(Mandatory)][psobject] $PlanResult)

    foreach ($write in $PlanResult.Writes) {
        Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $write.Path -Label 'transaction target'
        $actual = Get-PathState -LiteralPath $write.Path
        if (-not (Test-StateMatches -Expected $write.Before -Actual $actual)) {
            throw "PLAN_DRIFT: target changed before the transaction: $($write.Path)"
        }
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $transactionRoot = Join-Path $PlanResult.Plan.BackupParent $stamp
    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $transactionRoot -Label 'transaction backup'
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $transactionRoot -Label 'transaction backup'
    [IO.File]::WriteAllText((Join-Path $transactionRoot 'plan.json'), ($PlanResult.Plan | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

    $applied = [Collections.Generic.List[object]]::new()
    $createdDirectories = [Collections.Generic.List[string]]::new()
    try {
        foreach ($write in $PlanResult.Writes) {
            Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $write.Path -Label 'transaction target'
            $actual = Get-PathState -LiteralPath $write.Path
            if (-not (Test-StateMatches -Expected $write.Before -Actual $actual)) {
                throw "PLAN_DRIFT: target changed during the transaction: $($write.Path)"
            }

            $backupPath = $null
            if ($write.Before.Exists) {
                $backupPath = Join-Path $transactionRoot ('before-' + $write.Index.ToString('D4') + '.bin')
                [IO.File]::Copy($write.Path, $backupPath, $false)
                $backupState = Get-PathState -LiteralPath $backupPath
                if (-not [string]::Equals([string] $backupState.Sha256, [string] $write.Before.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Backup verification failed: $($write.Path)"
                }
            }

            $applied.Add([pscustomobject]@{ Write = $write; BackupPath = $backupPath })
            Write-AtomicBytes -Bytes $write.Bytes -Destination $write.Path -TransactionRoot $transactionRoot -AllowedRoot $PlanResult.Plan.UserProfileRoot -CreatedDirectories $createdDirectories
            $afterState = Get-PathState -LiteralPath $write.Path
            $expectedAfterHash = Get-Sha256Hex -Bytes $write.Bytes
            if (-not [string]::Equals([string] $afterState.Sha256, $expectedAfterHash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Post-write verification failed: $($write.Path)"
            }
        }

        return [pscustomobject]@{ Status = 'APPLIED'; BackupRoot = $transactionRoot; RollbackFailures = @() }
    } catch {
        $operationError = $_.Exception.Message
        $rollbackFailures = [Collections.Generic.List[string]]::new()
        for ($appliedIndex = $applied.Count - 1; $appliedIndex -ge 0; $appliedIndex--) {
            $entry = $applied[$appliedIndex]
            try {
                Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $entry.Write.Path -Label 'rollback target'
                $currentState = Get-PathState -LiteralPath $entry.Write.Path
                if (Test-StateMatches -Expected $entry.Write.Before -Actual $currentState) {
                    continue
                }
                if ($entry.Write.Before.Exists) {
                    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $entry.BackupPath -Label 'rollback backup'
                    $backupBytes = [IO.File]::ReadAllBytes($entry.BackupPath)
                    Write-AtomicBytes -Bytes $backupBytes -Destination $entry.Write.Path -TransactionRoot $transactionRoot -AllowedRoot $PlanResult.Plan.UserProfileRoot -CreatedDirectories $createdDirectories
                } elseif (Test-Path -LiteralPath $entry.Write.Path -PathType Leaf) {
                    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $transactionRoot -Label 'rollback backup'
                    $createdBackup = Join-Path $transactionRoot ('created-' + $entry.Write.Index.ToString('D4') + '.bin')
                    [IO.File]::Move($entry.Write.Path, $createdBackup)
                }
            } catch {
                $rollbackFailures.Add("$($entry.Write.Path): $($_.Exception.Message)")
            }
        }

        $uniqueCreatedDirectories = @($createdDirectories | Select-Object -Unique | Sort-Object Length -Descending)
        foreach ($createdDirectory in $uniqueCreatedDirectories) {
            try {
                Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $createdDirectory -Label 'rollback directory'
                if ((Test-Path -LiteralPath $createdDirectory -PathType Container) -and [IO.Directory]::GetFileSystemEntries($createdDirectory).Length -eq 0) {
                    Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $transactionRoot -Label 'rollback backup'
                    $directoryBackup = Join-Path $transactionRoot ('created-directory-' + [guid]::NewGuid().ToString('N'))
                    [IO.Directory]::Move($createdDirectory, $directoryBackup)
                }
            } catch {
                $rollbackFailures.Add("${createdDirectory}: $($_.Exception.Message)")
            }
        }

        foreach ($write in $PlanResult.Writes) {
            try {
                Assert-NoReparseTraversal -Root $PlanResult.Plan.UserProfileRoot -LiteralPath $write.Path -Label 'rollback verification'
                $restored = Get-PathState -LiteralPath $write.Path
                if (-not (Test-StateMatches -Expected $write.Before -Actual $restored)) {
                    $rollbackFailures.Add("$($write.Path): restored state does not match the Preview snapshot")
                }
            } catch {
                $rollbackFailures.Add("$($write.Path): $($_.Exception.Message)")
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

function Invoke-InstallerMain {
try {
    $profileRoot = Get-NormalizedProfileRoot -Path $UserProfileRoot
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding utf8 | ConvertFrom-Json -Depth 20
    if ([string]::IsNullOrWhiteSpace([string] $manifest.version)) {
        throw 'Package manifest version is missing.'
    }
    Assert-ManifestContract -PackageRoot $packageRoot -Manifest $manifest
    $selectedTools = Get-SelectedTools -Requested $Tool
    $planResult = New-InstallPlan -ProfileRoot $profileRoot -SelectedTools $selectedTools -PackageRoot $packageRoot -Manifest $manifest

    if ($Mode -eq 'Preview') {
        [pscustomobject]@{
            Mode = 'Preview'
            Status = 'PREVIEW'
            PlanSha256 = $planResult.PlanSha256
            Plan = $planResult.Plan
        } | ConvertTo-Json -Depth 14
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
            Message = 'The installation state changed after Preview; no files were written.'
        } | ConvertTo-Json -Depth 5
        exit 2
    }

    if ($planResult.Writes.Count -eq 0) {
        [pscustomobject]@{ Mode = 'Apply'; Status = 'APPLIED'; PlanSha256 = $planResult.PlanSha256; BackupRoot = $null; Plan = $planResult.Plan } | ConvertTo-Json -Depth 14
        exit 0
    }

    $transaction = Invoke-InstallTransaction -PlanResult $planResult
    $operationErrorProperty = $transaction.PSObject.Properties['OperationError']
    $operationError = if ($null -eq $operationErrorProperty) { $null } else { $operationErrorProperty.Value }
    [pscustomobject]@{
        Mode = 'Apply'
        Status = $transaction.Status
        PlanSha256 = $planResult.PlanSha256
        BackupRoot = $transaction.BackupRoot
        OperationError = $operationError
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
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallerMain
}
