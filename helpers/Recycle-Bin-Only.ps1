[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $LiteralPath,

    [Parameter(Mandatory)]
    [ValidateSet('File', 'Directory')]
    [string] $ExpectedType,

    [Parameter(Mandatory)]
    [long] $ExpectedFileCount,

    [Parameter(Mandatory)]
    [long] $ExpectedDirectoryCount,

    [Parameter(Mandatory)]
    [long] $ExpectedBytes,

    [string[]] $ProtectedRoot = @(),

    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
Set-StrictMode -Version 3.0

function Write-ResultAndExit {
    param(
        [Parameter(Mandatory)][string] $Status,
        [Parameter(Mandatory)][string] $ErrorCode,
        [Parameter(Mandatory)][string] $Message,
        [Parameter(Mandatory)][int] $ExitCode,
        [hashtable] $Evidence = @{}
    )

    $result = [ordered]@{
        SchemaVersion = 1
        Status = $Status
        ErrorCode = $ErrorCode
        Message = $Message
        LiteralPath = $LiteralPath
        Evidence = $Evidence
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 6 -Compress))
    exit $ExitCode
}

function Stop-Safely {
    param(
        [Parameter(Mandatory)][string] $ErrorCode,
        [Parameter(Mandatory)][string] $Message,
        [int] $ExitCode = 2,
        [hashtable] $Evidence = @{}
    )

    Write-ResultAndExit -Status 'FAILED' -ErrorCode $ErrorCode -Message $Message -ExitCode $ExitCode -Evidence $Evidence
}

function Get-ComparablePath {
    param([Parameter(Mandatory)][string] $PathValue)

    $fullPath = [System.IO.Path]::GetFullPath($PathValue)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $rootPath
    }
    return $fullPath.TrimEnd([char[]]@('\', '/'))
}

function Test-FullyQualifiedLocalPath {
    param([Parameter(Mandatory)][string] $PathValue)

    return $PathValue.Length -ge 3 -and
        [char]::IsLetter($PathValue[0]) -and
        $PathValue[1] -eq ':' -and
        ($PathValue[2] -eq '\' -or $PathValue[2] -eq '/')
}

function Resolve-CanonicalExistingPath {
    param([Parameter(Mandatory)][string] $PathValue)

    $fullPath = Get-ComparablePath $PathValue
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $relativePath = $fullPath.Substring($rootPath.Length)
    if ([string]::IsNullOrEmpty($relativePath)) {
        return $rootPath
    }

    $canonicalPath = $rootPath
    $segments = @($relativePath.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries))
    foreach ($segment in $segments) {
        $candidatePath = Join-Path -Path $canonicalPath -ChildPath $segment
        $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
        $canonicalPath = Join-Path -Path $canonicalPath -ChildPath $item.Name
    }
    return Get-ComparablePath $canonicalPath
}

function Test-PathSame {
    param(
        [Parameter(Mandatory)][string] $Left,
        [Parameter(Mandatory)][string] $Right
    )

    return [string]::Equals((Get-ComparablePath $Left), (Get-ComparablePath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathSameOrChild {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Root
    )

    $candidatePath = Get-ComparablePath $Candidate
    $rootPath = Get-ComparablePath $Root
    if ([string]::Equals($candidatePath, $rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $rootPrefix = $rootPath.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TargetSnapshot {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo] $TargetItem)

    if (-not $TargetItem.PSIsContainer) {
        return [pscustomobject]@{
            Type = 'File'
            FileCount = [long] 1
            DirectoryCount = [long] 0
            Bytes = [long] $TargetItem.Length
        }
    }

    $fileCount = [long] 0
    $directoryCount = [long] 1
    $byteCount = [long] 0
    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($TargetItem.FullName)

    while ($pendingDirectories.Count -gt 0) {
        $directoryPath = $pendingDirectories.Pop()
        $children = @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Stop-Safely -ErrorCode 'DESCENDANT_REPARSE_POINT' -Message "A descendant is a reparse point: $($child.FullName)"
            }
            if ($child.PSIsContainer) {
                $directoryCount++
                $pendingDirectories.Push($child.FullName)
            } elseif ($child -is [System.IO.FileInfo]) {
                $fileCount++
                $byteCount += [long] $child.Length
            } else {
                Stop-Safely -ErrorCode 'TARGET_ITEM_UNSUPPORTED' -Message "A descendant has an unsupported filesystem type: $($child.FullName)"
            }
        }
    }

    return [pscustomobject]@{
        Type = 'Directory'
        FileCount = $fileCount
        DirectoryCount = $directoryCount
        Bytes = $byteCount
    }
}

function Get-RecycleMetadataNames {
    param([Parameter(Mandatory)][string] $RecyclePath)

    if (-not (Test-Path -LiteralPath $RecyclePath -PathType Container)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $RecyclePath -Force -File -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { $_.Name }
    )
}

function Read-RecycleMetadata {
    param([Parameter(Mandatory)][string] $MetadataPath)

    $bytes = [System.IO.File]::ReadAllBytes($MetadataPath)
    if ($bytes.Length -lt 24) {
        throw 'Recycle metadata is shorter than 24 bytes.'
    }

    $formatVersion = [BitConverter]::ToInt64($bytes, 0)
    $originalSize = [BitConverter]::ToInt64($bytes, 8)
    $deletedFileTime = [BitConverter]::ToInt64($bytes, 16)
    if ($formatVersion -eq 1) {
        if ($bytes.Length -lt 26) { throw 'Version 1 recycle metadata is incomplete.' }
        $originalPath = [Text.Encoding]::Unicode.GetString($bytes, 24, $bytes.Length - 24).TrimEnd([char[]]@([char] 0))
    } elseif ($formatVersion -eq 2) {
        if ($bytes.Length -lt 28) { throw 'Version 2 recycle metadata is incomplete.' }
        $pathLength = [BitConverter]::ToUInt32($bytes, 24)
        $pathByteCount = [int64] $pathLength * 2
        if ($pathLength -eq 0 -or 28 + $pathByteCount -gt $bytes.Length) {
            throw 'Version 2 recycle metadata path length is invalid.'
        }
        $originalPath = [Text.Encoding]::Unicode.GetString($bytes, 28, [int] $pathByteCount).TrimEnd([char[]]@([char] 0))
    } else {
        throw "Unsupported recycle metadata version: $formatVersion"
    }

    return [pscustomobject]@{
        Version = $formatVersion
        OriginalPath = $originalPath
        OriginalSize = $originalSize
        DeletedAtUtc = [DateTime]::FromFileTimeUtc($deletedFileTime)
    }
}

function Get-RecycleBinUsageBytes {
    param([Parameter(Mandatory)][string] $VolumeRoot)

    if ($null -eq ('DeletionSafety.NativeRecycleBin' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DeletionSafety
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct SHQUERYRBINFO
    {
        internal int cbSize;
        internal long i64Size;
        internal long i64NumItems;
    }

    public static class NativeRecycleBin
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
        private static extern int SHQueryRecycleBin(string rootPath, ref SHQUERYRBINFO info);

        public static long GetSize(string rootPath)
        {
            SHQUERYRBINFO info = new SHQUERYRBINFO();
            info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
            int result = SHQueryRecycleBin(rootPath, ref info);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
            return info.i64Size;
        }
    }
}
'@ -ErrorAction Stop
    }

    return [long] [DeletionSafety.NativeRecycleBin]::GetSize($VolumeRoot)
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Stop-Safely -ErrorCode 'PLATFORM_UNSUPPORTED' -Message 'This helper supports Windows only.'
    }
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        Stop-Safely -ErrorCode 'PATH_NOT_ABSOLUTE' -Message 'LiteralPath must be an absolute filesystem path.'
    }
    if ($LiteralPath.StartsWith('\\', [StringComparison]::Ordinal)) {
        Stop-Safely -ErrorCode 'UNC_PATH_UNSUPPORTED' -Message 'UNC and device paths are not supported.'
    }
    if (-not (Test-FullyQualifiedLocalPath $LiteralPath)) {
        Stop-Safely -ErrorCode 'PATH_NOT_ABSOLUTE' -Message 'LiteralPath must be a fully qualified local-drive path.'
    }
    if ($LiteralPath.IndexOf('*') -ge 0 -or $LiteralPath.IndexOf('?') -ge 0) {
        Stop-Safely -ErrorCode 'PATH_WILDCARD_UNSUPPORTED' -Message 'Wildcard characters are not allowed.'
    }
    if ($LiteralPath.IndexOf(':', 2) -ge 0) {
        Stop-Safely -ErrorCode 'ALTERNATE_STREAM_UNSUPPORTED' -Message 'Alternate data stream paths are not supported.'
    }

    $lexicalPath = Get-ComparablePath $LiteralPath
    $volumeRoot = [System.IO.Path]::GetPathRoot($lexicalPath)
    if (Test-PathSame $lexicalPath $volumeRoot) {
        Stop-Safely -ErrorCode 'TARGET_IS_VOLUME_ROOT' -Message 'A volume root cannot be recycled by this helper.'
    }
    if (-not (Test-Path -LiteralPath $lexicalPath)) {
        Stop-Safely -ErrorCode 'TARGET_NOT_FOUND' -Message 'The target does not exist.'
    }

    $normalizedPath = Resolve-CanonicalExistingPath $lexicalPath
    $volumeRoot = [System.IO.Path]::GetPathRoot($normalizedPath)

    $targetItem = Get-Item -LiteralPath $normalizedPath -Force -ErrorAction Stop
    if ($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Stop-Safely -ErrorCode 'TARGET_REPARSE_POINT' -Message 'The target is a reparse point.'
    }

    $ancestorPath = Split-Path -Parent $targetItem.FullName
    while (-not [string]::IsNullOrEmpty($ancestorPath)) {
        $ancestorItem = Get-Item -LiteralPath $ancestorPath -Force -ErrorAction Stop
        if ($ancestorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Stop-Safely -ErrorCode 'ANCESTOR_REPARSE_POINT' -Message "An ancestor is a reparse point: $ancestorPath"
        }
        $nextAncestor = Split-Path -Parent $ancestorPath
        if ([string]::Equals($nextAncestor, $ancestorPath, [StringComparison]::OrdinalIgnoreCase)) { break }
        $ancestorPath = $nextAncestor
    }

    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $exactProtectedRoots = @($userProfile) + @($ProtectedRoot)
    foreach ($protectedPath in $exactProtectedRoots) {
        if ([string]::IsNullOrWhiteSpace($protectedPath)) { continue }
        if ($protectedPath.StartsWith('\\', [StringComparison]::Ordinal) -or -not (Test-FullyQualifiedLocalPath $protectedPath)) {
            Stop-Safely -ErrorCode 'PROTECTED_ROOT_INVALID' -Message "ProtectedRoot is not absolute: $protectedPath"
        }
        $normalizedProtectedPath = Get-ComparablePath $protectedPath
        if (-not (Test-Path -LiteralPath $normalizedProtectedPath)) {
            Stop-Safely -ErrorCode 'PROTECTED_ROOT_NOT_FOUND' -Message "ProtectedRoot does not exist: $normalizedProtectedPath"
        }
        $normalizedProtectedPath = Resolve-CanonicalExistingPath $normalizedProtectedPath
        if (Test-PathSameOrChild $normalizedProtectedPath $normalizedPath) {
            Stop-Safely -ErrorCode 'PROTECTED_TARGET' -Message "The target is equal to or contains a protected root: $normalizedProtectedPath"
        }
    }

    $protectedSubtrees = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData),
        (Join-Path $userProfile '.codex'),
        (Join-Path $userProfile '.claude'),
        (Join-Path $userProfile '.agents'),
        (Join-Path $userProfile '.config'),
        (Join-Path $volumeRoot '$Recycle.Bin'),
        (Join-Path $volumeRoot 'System Volume Information')
    )
    foreach ($protectedSubtree in $protectedSubtrees) {
        if ([string]::IsNullOrWhiteSpace($protectedSubtree)) { continue }
        if ((Test-PathSameOrChild $normalizedPath $protectedSubtree) -or (Test-PathSameOrChild $protectedSubtree $normalizedPath)) {
            Stop-Safely -ErrorCode 'PROTECTED_TARGET' -Message "The target overlaps a protected system or configuration subtree: $protectedSubtree"
        }
    }

    if ($ExpectedFileCount -lt 0 -or $ExpectedDirectoryCount -lt 0 -or $ExpectedBytes -lt 0) {
        Stop-Safely -ErrorCode 'EXPECTED_SNAPSHOT_INVALID' -Message 'Expected counts and bytes must be non-negative.'
    }
    $snapshot = Get-TargetSnapshot -TargetItem $targetItem
    if ($snapshot.Type -ne $ExpectedType) {
        Stop-Safely -ErrorCode 'SNAPSHOT_TYPE_MISMATCH' -Message "Expected $ExpectedType but found $($snapshot.Type)."
    }
    if ($snapshot.FileCount -ne $ExpectedFileCount -or $snapshot.DirectoryCount -ne $ExpectedDirectoryCount -or $snapshot.Bytes -ne $ExpectedBytes) {
        Stop-Safely -ErrorCode 'SNAPSHOT_DRIFT' -Message 'The target counts or byte size changed after authorization.' -Evidence @{
            ActualFileCount = $snapshot.FileCount
            ActualDirectoryCount = $snapshot.DirectoryCount
            ActualBytes = $snapshot.Bytes
        }
    }

    if (-not [Environment]::UserInteractive) {
        Stop-Safely -ErrorCode 'NON_INTERACTIVE_SESSION' -Message 'The recycle API requires an interactive Windows session.'
    }

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSessionId = (Get-Process -Id $PID).SessionId
    try {
        $explorerProcesses = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
        $sameSessionExplorers = @($explorerProcesses | Where-Object { $_.SessionId -eq $currentSessionId })
        if ($explorerProcesses.Count -eq 0) {
            Stop-Safely -ErrorCode 'EXPLORER_NOT_FOUND' -Message 'No interactive Explorer process is running.'
        }
        if ($sameSessionExplorers.Count -eq 0) {
            Stop-Safely -ErrorCode 'SESSION_MISMATCH' -Message 'Explorer is running in a different Windows session.'
        }
        $matchingExplorerCount = 0
        foreach ($explorerProcess in $sameSessionExplorers) {
            $ownerSidResult = Invoke-CimMethod -InputObject $explorerProcess -MethodName GetOwnerSid -ErrorAction Stop
            if ($ownerSidResult.ReturnValue -eq 0 -and [string]::Equals($ownerSidResult.Sid, $currentIdentity.User.Value, [StringComparison]::OrdinalIgnoreCase)) {
                $matchingExplorerCount++
            }
        }
        if ($matchingExplorerCount -eq 0) {
            Stop-Safely -ErrorCode 'IDENTITY_MISMATCH' -Message 'The helper identity does not match Explorer in the current session.'
        }
    } catch {
        if ($_.Exception.Message -like '*IDENTITY_MISMATCH*') { throw }
        Stop-Safely -ErrorCode 'IDENTITY_UNVERIFIABLE' -Message 'Explorer ownership could not be verified; refusing to recycle.'
    }

    $driveLetter = $volumeRoot.Substring(0, 1)
    try {
        $volume = @(Get-Volume -DriveLetter $driveLetter -ErrorAction Stop)
    } catch {
        Stop-Safely -ErrorCode 'VOLUME_UNVERIFIABLE' -Message 'The target volume could not be inspected.'
    }
    if ($volume.Count -ne 1 -or [string] $volume[0].DriveType -ne 'Fixed') {
        Stop-Safely -ErrorCode 'VOLUME_UNSUPPORTED' -Message 'Only one local fixed Windows volume is supported.'
    }

    $volumeIdMatch = [regex]::Match([string] $volume[0].UniqueId, '\{[^}]+\}')
    if (-not $volumeIdMatch.Success) {
        Stop-Safely -ErrorCode 'RECYCLE_POLICY_UNVERIFIABLE' -Message 'The target volume identity could not be mapped to Recycle Bin policy.'
    }
    $bitBucketPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket'
    $globalPolicy = Get-ItemProperty -LiteralPath $bitBucketPath -ErrorAction Stop
    $globalNukeProperty = $globalPolicy.PSObject.Properties['NukeOnDelete']
    if ($null -ne $globalNukeProperty -and [int] $globalNukeProperty.Value -ne 0) {
        Stop-Safely -ErrorCode 'RECYCLE_DISABLED' -Message 'The current-user global policy is configured to delete permanently instead of recycling.'
    }

    $policyPath = $bitBucketPath + '\Volume\' + $volumeIdMatch.Value
    if (-not (Test-Path -LiteralPath $policyPath -PathType Container)) {
        Stop-Safely -ErrorCode 'RECYCLE_POLICY_UNVERIFIABLE' -Message 'No per-volume Recycle Bin policy exists for the current user.'
    }
    $policy = Get-ItemProperty -LiteralPath $policyPath -ErrorAction Stop
    $nukeProperty = $policy.PSObject.Properties['NukeOnDelete']
    $capacityProperty = $policy.PSObject.Properties['MaxCapacity']
    if ($null -eq $nukeProperty -or $null -eq $capacityProperty) {
        Stop-Safely -ErrorCode 'RECYCLE_POLICY_UNVERIFIABLE' -Message 'Required Recycle Bin policy values are missing.'
    }
    if ([int] $nukeProperty.Value -ne 0) {
        Stop-Safely -ErrorCode 'RECYCLE_DISABLED' -Message 'Windows policy is configured to delete permanently instead of recycling.'
    }
    $capacityBytes = [long] $capacityProperty.Value * 1MB
    if ($capacityBytes -le 0 -or $snapshot.Bytes -gt $capacityBytes) {
        Stop-Safely -ErrorCode 'RECYCLE_CAPACITY_EXCEEDED' -Message 'The target is larger than the configured Recycle Bin capacity.' -Evidence @{
            TargetBytes = $snapshot.Bytes
            CapacityBytes = $capacityBytes
        }
    }
    try {
        $currentRecycleBytes = Get-RecycleBinUsageBytes -VolumeRoot $volumeRoot
    } catch {
        Stop-Safely -ErrorCode 'RECYCLE_USAGE_UNVERIFIABLE' -Message 'The current Recycle Bin usage could not be queried; refusing to risk capacity eviction.'
    }
    if ($currentRecycleBytes -lt 0 -or $currentRecycleBytes -gt $capacityBytes) {
        Stop-Safely -ErrorCode 'RECYCLE_USAGE_INVALID' -Message 'The current Recycle Bin usage is outside the configured capacity range.' -Evidence @{
            CurrentRecycleBytes = $currentRecycleBytes
            CapacityBytes = $capacityBytes
        }
    }
    $availableRecycleBytes = $capacityBytes - $currentRecycleBytes
    if ($snapshot.Bytes -gt $availableRecycleBytes) {
        Stop-Safely -ErrorCode 'RECYCLE_CAPACITY_INSUFFICIENT' -Message 'The target does not fit in the remaining Recycle Bin capacity without risking eviction of existing items.' -Evidence @{
            TargetBytes = $snapshot.Bytes
            CurrentRecycleBytes = $currentRecycleBytes
            AvailableRecycleBytes = $availableRecycleBytes
            CapacityBytes = $capacityBytes
        }
    }

    $recyclePath = Join-Path $volumeRoot ('$Recycle.Bin\' + $currentIdentity.User.Value)
    try {
        $metadataBefore = @(Get-RecycleMetadataNames -RecyclePath $recyclePath)
    } catch {
        Stop-Safely -ErrorCode 'RECYCLE_BIN_UNVERIFIABLE' -Message 'The current user Recycle Bin metadata cannot be read.'
    }

    $commonEvidence = @{
        NormalizedPath = $normalizedPath
        Type = $snapshot.Type
        FileCount = $snapshot.FileCount
        DirectoryCount = $snapshot.DirectoryCount
        Bytes = $snapshot.Bytes
        Identity = $currentIdentity.Name
        Sid = $currentIdentity.User.Value
        SessionId = $currentSessionId
        VolumeId = $volumeIdMatch.Value
        RecycleCapacityBytes = $capacityBytes
        RecycleUsedBytes = $currentRecycleBytes
        RecycleAvailableBytes = $availableRecycleBytes
    }
    if ($ValidateOnly) {
        Write-ResultAndExit -Status 'VALIDATED' -ErrorCode 'NONE' -Message 'All preflight checks passed; no recycle operation was performed.' -ExitCode 0 -Evidence $commonEvidence
    }

    $operationStartedAtUtc = [DateTime]::UtcNow
    try {
        [void] (Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop)
        if ($snapshot.Type -eq 'Directory') {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $normalizedPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
            )
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $normalizedPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
            )
        }
    } catch {
        if (-not (Test-Path -LiteralPath $normalizedPath)) {
            Write-ResultAndExit -Status 'SAFETY_INCIDENT' -ErrorCode 'RECYCLE_EXCEPTION_SOURCE_MISSING' -Message 'The recycle API threw after the source disappeared; recoverability is unverified.' -ExitCode 4 -Evidence $commonEvidence
        }
        Stop-Safely -ErrorCode 'RECYCLE_OPERATION_FAILED' -Message $_.Exception.Message -ExitCode 3 -Evidence $commonEvidence
    }

    if (Test-Path -LiteralPath $normalizedPath) {
        Stop-Safely -ErrorCode 'SOURCE_STILL_EXISTS' -Message 'The recycle API returned but the source still exists.' -ExitCode 3 -Evidence $commonEvidence
    }

    try {
        $beforeSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($metadataName in $metadataBefore) { [void] $beforeSet.Add($metadataName) }
        $matchingMetadata = @()
        for ($attempt = 0; $attempt -lt 20 -and $matchingMetadata.Count -eq 0; $attempt++) {
            if ($attempt -gt 0) { Start-Sleep -Milliseconds 100 }
            $metadataAfter = @(Get-RecycleMetadataNames -RecyclePath $recyclePath)
            $newMetadataNames = @($metadataAfter | Where-Object { -not $beforeSet.Contains($_) })
            $matchingMetadata = @($newMetadataNames | ForEach-Object {
                $metadataPath = Join-Path $recyclePath $_
                try {
                    $metadata = Read-RecycleMetadata -MetadataPath $metadataPath
                    $pathMatches = Test-PathSame $metadata.OriginalPath $normalizedPath
                    $timeMatches = $metadata.DeletedAtUtc -ge $operationStartedAtUtc.AddSeconds(-5) -and $metadata.DeletedAtUtc -le [DateTime]::UtcNow.AddSeconds(5)
                    $sizeMatches = $snapshot.Type -eq 'Directory' -or $metadata.OriginalSize -eq $snapshot.Bytes
                    if ($pathMatches -and $timeMatches -and $sizeMatches) {
                        [pscustomobject]@{ Name = $_; Metadata = $metadata }
                    }
                } catch {
                    $null
                }
            })
        }
    } catch {
        Write-ResultAndExit -Status 'SAFETY_INCIDENT' -ErrorCode 'RECYCLE_EVIDENCE_READ_FAILED' -Message 'The source disappeared but post-operation Recycle Bin evidence could not be read.' -ExitCode 4 -Evidence $commonEvidence
    }

    if ($matchingMetadata.Count -ne 1) {
        Write-ResultAndExit -Status 'SAFETY_INCIDENT' -ErrorCode 'RECYCLE_EVIDENCE_MISSING' -Message 'The source disappeared but one exact new Recycle Bin metadata record could not be proven.' -ExitCode 4 -Evidence $commonEvidence
    }

    $successEvidence = $commonEvidence.Clone()
    $successEvidence['RecycleMetadataName'] = $matchingMetadata[0].Name
    $successEvidence['RecycleMetadataVersion'] = $matchingMetadata[0].Metadata.Version
    $successEvidence['DeletedAtUtc'] = $matchingMetadata[0].Metadata.DeletedAtUtc.ToString('o')
    Write-ResultAndExit -Status 'RECYCLED_VERIFIED' -ErrorCode 'NONE' -Message 'The source is absent and an exact new current-user Recycle Bin metadata record was verified.' -ExitCode 0 -Evidence $successEvidence
} catch {
    Write-ResultAndExit -Status 'FAILED' -ErrorCode 'INTERNAL_ERROR' -Message $_.Exception.Message -ExitCode 5
}
