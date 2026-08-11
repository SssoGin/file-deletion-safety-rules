[CmdletBinding()]
param(
    [ValidateSet('All', 'Codex', 'Claude', 'OpenCode')]
    [string[]] $Tool = @('All'),

    [string] $UserProfileRoot = [Environment]::GetFolderPath('UserProfile')
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

    if ($Requested -contains 'All') { return @('Codex', 'Claude', 'OpenCode') }
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

function Get-StrictTextInfo {
    param([Parameter(Mandatory)][string] $LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Bytes = [byte[]]::new(0); Text = ''; HasUtf8Bom = $false }
    }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Exists = $true; Bytes = $bytes; Text = $text; HasUtf8Bom = $hasBom }
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

function Add-Check {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Checks,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [AllowNull()] $Detail
    )

    $Checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail })
}

try {
    $profileRoot = Get-NormalizedProfileRoot -Path $UserProfileRoot
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding utf8 | ConvertFrom-Json -Depth 30
    Assert-ManifestContract -PackageRoot $packageRoot -Manifest $manifest
    $selectedTools = Get-SelectedTools -Requested $Tool
    $checks = [Collections.Generic.List[object]]::new()
    $unsupportedUnmanagedHeadings = @(Get-UnsupportedUnmanagedHeadings -Manifest $manifest)
    $manifestIdentityValid = [int] $manifest.schemaVersion -eq 2 -and
        [string]::Equals([string] $manifest.name, 'file-deletion-safety-rules', [StringComparison]::Ordinal) -and
        -not [string]::IsNullOrWhiteSpace([string] $manifest.version) -and
        $null -ne $manifest.PSObject.Properties['files'] -and
        @($manifest.files.PSObject.Properties).Count -gt 0
    Add-Check -Checks $checks -Name 'ManifestIdentity' -Passed $manifestIdentityValid -Detail ([pscustomobject]@{ SchemaVersion = $manifest.schemaVersion; Name = $manifest.name; Version = $manifest.version })

    $policySource = Resolve-ChildPath -Root $packageRoot -RelativePath ([string] $manifest.policy.source) -Label 'policy.source'
    $helperSource = Resolve-ChildPath -Root $packageRoot -RelativePath ([string] $manifest.helper.source) -Label 'helper.source'
    $packagePolicyHash = if (Test-Path -LiteralPath $policySource -PathType Leaf) { Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($policySource)) } else { '' }
    $packageHelperHash = if (Test-Path -LiteralPath $helperSource -PathType Leaf) { Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($helperSource)) } else { '' }
    Add-Check -Checks $checks -Name 'PackagePolicyHash' -Passed ([string]::Equals($packagePolicyHash, [string] $manifest.policy.sha256, [StringComparison]::OrdinalIgnoreCase)) -Detail ([pscustomobject]@{ Expected = [string] $manifest.policy.sha256; Actual = $packagePolicyHash })
    Add-Check -Checks $checks -Name 'PackageHelperHash' -Passed ([string]::Equals($packageHelperHash, [string] $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase)) -Detail ([pscustomobject]@{ Expected = [string] $manifest.helper.sha256; Actual = $packageHelperHash })

    if ($null -ne $manifest.PSObject.Properties['files']) {
        foreach ($fileProperty in $manifest.files.PSObject.Properties) {
            $packageFilePath = Resolve-ChildPath -Root $packageRoot -RelativePath ([string] $fileProperty.Name) -Label 'files entry'
            $actualHash = if (Test-Path -LiteralPath $packageFilePath -PathType Leaf) { Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($packageFilePath)) } else { '' }
            Add-Check -Checks $checks -Name ('PackageFileHash:' + $fileProperty.Name) -Passed ([string]::Equals($actualHash, [string] $fileProperty.Value, [StringComparison]::OrdinalIgnoreCase)) -Detail ([pscustomobject]@{ Expected = [string] $fileProperty.Value; Actual = $actualHash })
        }
    }

    $sharedRoot = Resolve-ChildPath -Root $profileRoot -RelativePath ([string] $manifest.sharedInstallDirectory) -Label 'sharedInstallDirectory'
    $policyTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $manifest.policy.installedName) -Label 'policy.installedName'
    $helperTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $manifest.helper.installedName) -Label 'helper.installedName'
    $receiptTarget = Resolve-ChildPath -Root $sharedRoot -RelativePath ([string] $manifest.receipt.installedName) -Label 'receipt.installedName'
    $installedPolicyHash = if (Test-Path -LiteralPath $policyTarget -PathType Leaf) { Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($policyTarget)) } else { '' }
    $installedHelperHash = if (Test-Path -LiteralPath $helperTarget -PathType Leaf) { Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($helperTarget)) } else { '' }
    Add-Check -Checks $checks -Name 'InstalledPolicyHash' -Passed ([string]::Equals($installedPolicyHash, [string] $manifest.policy.sha256, [StringComparison]::OrdinalIgnoreCase)) -Detail ([pscustomobject]@{ Path = $policyTarget; Expected = [string] $manifest.policy.sha256; Actual = $installedPolicyHash })
    Add-Check -Checks $checks -Name 'InstalledHelperHash' -Passed ([string]::Equals($installedHelperHash, [string] $manifest.helper.sha256, [StringComparison]::OrdinalIgnoreCase)) -Detail ([pscustomobject]@{ Path = $helperTarget; Expected = [string] $manifest.helper.sha256; Actual = $installedHelperHash })

    $beginMarker = [string] $manifest.managedMarkers.begin
    $endMarker = [string] $manifest.managedMarkers.end
    $actualInstalledTools = [Collections.Generic.List[string]]::new()
    foreach ($toolName in @('Codex', 'Claude', 'OpenCode')) {
        $toolSpec = $manifest.tools.$toolName
        $configPath = Resolve-ChildPath -Root $profileRoot -RelativePath ([string] $toolSpec.config) -Label "$toolName.config"
        $configInfo = Get-StrictTextInfo -LiteralPath $configPath
        $isSelected = $selectedTools -contains $toolName
        if (-not $configInfo.Exists) {
            if ($isSelected) {
                Add-Check -Checks $checks -Name "$toolName.ManagedBlockExact" -Passed $false -Detail ([pscustomobject]@{ Path = $configPath; Reason = 'ConfigMissing' })
            }
            continue
        }

        $beginCount = ([regex]::Matches($configInfo.Text, [regex]::Escape($beginMarker))).Count
        $endCount = ([regex]::Matches($configInfo.Text, [regex]::Escape($endMarker))).Count
        $pattern = '(?ms)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
        $matches = [regex]::Matches($configInfo.Text, $pattern)
        $newline = if ($configInfo.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $adapterPath = Resolve-ChildPath -Root $packageRoot -RelativePath ([string] $toolSpec.adapter) -Label "$toolName.adapter"
        $adapterInfo = Get-StrictTextInfo -LiteralPath $adapterPath
        $expectedBlock = ($adapterInfo.Text.Replace('{{POLICY_PATH}}', $policyTarget) -replace "`r?`n", $newline).TrimEnd([char[]]@("`r", "`n"))
        $exact = $beginCount -eq 1 -and $endCount -eq 1 -and $matches.Count -eq 1 -and
            [string]::Equals($matches[0].Value, $expectedBlock, [StringComparison]::Ordinal) -and
            -not $configInfo.Text.Contains('{{POLICY_PATH}}') -and
            -not (Test-ContainsUnsupportedUnmanagedHeading -Text $configInfo.Text -Headings $unsupportedUnmanagedHeadings -BeginMarker $beginMarker -EndMarker $endMarker)
        if ($exact) { $actualInstalledTools.Add($toolName) }
        if ($isSelected) {
            Add-Check -Checks $checks -Name "$toolName.ManagedBlockExact" -Passed $exact -Detail ([pscustomobject]@{ Path = $configPath; BeginCount = $beginCount; EndCount = $endCount; MatchCount = $matches.Count })
        }
    }

    $expectedReceiptBytes = New-ReceiptBytes -Manifest $manifest -PolicyHash ([string] $manifest.policy.sha256) -HelperHash ([string] $manifest.helper.sha256) -InstalledTools @($actualInstalledTools)
    $expectedReceiptHash = Get-Sha256Hex -Bytes $expectedReceiptBytes
    $installedReceiptHash = if (Test-Path -LiteralPath $receiptTarget -PathType Leaf) { Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($receiptTarget)) } else { '' }
    Add-Check -Checks $checks -Name 'InstalledReceiptExact' -Passed ([string]::Equals($installedReceiptHash, $expectedReceiptHash, [StringComparison]::OrdinalIgnoreCase)) -Detail ([pscustomobject]@{ Path = $receiptTarget; Expected = $expectedReceiptHash; Actual = $installedReceiptHash; InstalledTools = @($actualInstalledTools) })

    $passed = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
    [pscustomobject]@{
        Passed = $passed
        PackageName = [string] $manifest.name
        PackageVersion = [string] $manifest.version
        UserProfileRoot = $profileRoot
        Checks = @($checks)
    } | ConvertTo-Json -Depth 12
    if (-not $passed) { exit 1 }
    exit 0
} catch {
    [pscustomobject]@{ Passed = $false; Status = 'FAILED'; Message = $_.Exception.Message } | ConvertTo-Json -Depth 5
    exit 1
}
