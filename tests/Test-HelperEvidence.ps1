[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Write-RecycleMetadataV2 {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][string] $OriginalPath,
        [Parameter(Mandatory)][long] $OriginalSize,
        [Parameter(Mandatory)][DateTime] $DeletedAtUtc
    )

    $terminatedPath = $OriginalPath + [char] 0
    $pathBytes = [Text.Encoding]::Unicode.GetBytes($terminatedPath)
    $bytes = [byte[]]::new(28 + $pathBytes.Length)
    [BitConverter]::GetBytes([long] 2).CopyTo($bytes, 0)
    [BitConverter]::GetBytes($OriginalSize).CopyTo($bytes, 8)
    [BitConverter]::GetBytes($DeletedAtUtc.ToFileTimeUtc()).CopyTo($bytes, 16)
    [BitConverter]::GetBytes([uint32] $terminatedPath.Length).CopyTo($bytes, 24)
    $pathBytes.CopyTo($bytes, 28)
    [IO.File]::WriteAllBytes($LiteralPath, $bytes)
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helperPath = Join-Path $packageRoot 'helpers\Recycle-Bin-Only.ps1'
$helperText = Get-Content -Raw -LiteralPath $helperPath -Encoding utf8
Assert-True -Condition $helperText.Contains('function Find-NewRecycleEvidence') -Message 'RED: helper has no testable paired $I/$R evidence function.'
Assert-True -Condition $helperText.Contains("`$MyInvocation.InvocationName -ne '.'") -Message 'RED: helper cannot be dot-sourced without executing its recycle entrypoint.'
Assert-True -Condition $helperText.Contains('function Test-TargetSnapshotSame') -Message 'RED: helper has no reusable snapshot equality check.'
Assert-True -Condition $helperText.Contains('$finalSnapshot = Get-TargetSnapshot -TargetItem $finalTargetItem') -Message 'RED: helper does not re-snapshot immediately before the recycle API.'
Assert-True -Condition $helperText.Contains('ExpectedMetadataFingerprint is required for a recycle operation.') -Message 'RED: helper permits a recycle operation without the confirmed metadata fingerprint.'

. $helperPath -LiteralPath 'C:\definition-only-fixture' -ExpectedType File -ExpectedFileCount 1 -ExpectedDirectoryCount 0 -ExpectedBytes 0

$fixtureRoot = Join-Path $packageRoot ('.test-profile\helper-evidence\' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$deletedAtUtc = [DateTime]::UtcNow
$operationStartedAtUtc = $deletedAtUtc.AddSeconds(-1)

$metadataOnlyRoot = Join-Path $fixtureRoot 'metadata-only'
[IO.Directory]::CreateDirectory($metadataOnlyRoot) | Out-Null
$metadataOnlyOriginal = 'E:\fixture\metadata-only.txt'
Write-RecycleMetadataV2 -LiteralPath (Join-Path $metadataOnlyRoot '$I000001.txt') -OriginalPath $metadataOnlyOriginal -OriginalSize 5 -DeletedAtUtc $deletedAtUtc
$metadataOnlyMatches = @(Find-NewRecycleEvidence -RecyclePath $metadataOnlyRoot -EntryNamesBefore @() -NormalizedPath $metadataOnlyOriginal -OperationStartedAtUtc $operationStartedAtUtc -Snapshot ([pscustomobject]@{ Type = 'File'; FileCount = 1L; DirectoryCount = 0L; Bytes = 5L; Fingerprint = 'fixture' }) -Attempts 1 -DelayMilliseconds 0)
Assert-True -Condition ($metadataOnlyMatches.Count -eq 0) -Message 'A matching $I without its paired $R was accepted.'

$matchingFileRoot = Join-Path $fixtureRoot 'matching-file'
[IO.Directory]::CreateDirectory($matchingFileRoot) | Out-Null
$matchingFileOriginal = 'E:\fixture\matching-file.txt'
Write-RecycleMetadataV2 -LiteralPath (Join-Path $matchingFileRoot '$I000002.txt') -OriginalPath $matchingFileOriginal -OriginalSize 5 -DeletedAtUtc $deletedAtUtc
[IO.File]::WriteAllBytes((Join-Path $matchingFileRoot '$R000002.txt'), [Text.Encoding]::UTF8.GetBytes('12345'))
$matchingFileSnapshot = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath (Join-Path $matchingFileRoot '$R000002.txt') -Force)
$matchingFileMatches = @(Find-NewRecycleEvidence -RecyclePath $matchingFileRoot -EntryNamesBefore @() -NormalizedPath $matchingFileOriginal -OperationStartedAtUtc $operationStartedAtUtc -Snapshot $matchingFileSnapshot -Attempts 1 -DelayMilliseconds 0)
Assert-True -Condition ($matchingFileMatches.Count -eq 1) -Message 'An exact new $I/$R file pair was not accepted.'
Assert-True -Condition ([string]::Equals($matchingFileMatches[0].DataName, '$R000002.txt', [StringComparison]::Ordinal)) -Message 'The paired $R name was not reported.'

$wrongSizeRoot = Join-Path $fixtureRoot 'wrong-size'
[IO.Directory]::CreateDirectory($wrongSizeRoot) | Out-Null
$wrongSizeOriginal = 'E:\fixture\wrong-size.txt'
Write-RecycleMetadataV2 -LiteralPath (Join-Path $wrongSizeRoot '$I000003.txt') -OriginalPath $wrongSizeOriginal -OriginalSize 5 -DeletedAtUtc $deletedAtUtc
[IO.File]::WriteAllBytes((Join-Path $wrongSizeRoot '$R000003.txt'), [Text.Encoding]::UTF8.GetBytes('1234'))
$wrongSizeMatches = @(Find-NewRecycleEvidence -RecyclePath $wrongSizeRoot -EntryNamesBefore @() -NormalizedPath $wrongSizeOriginal -OperationStartedAtUtc $operationStartedAtUtc -Snapshot ([pscustomobject]@{ Type = 'File'; FileCount = 1L; DirectoryCount = 0L; Bytes = 5L; Fingerprint = 'fixture' }) -Attempts 1 -DelayMilliseconds 0)
Assert-True -Condition ($wrongSizeMatches.Count -eq 0) -Message 'A paired $R with the wrong byte length was accepted.'

$preexistingDataRoot = Join-Path $fixtureRoot 'preexisting-data'
[IO.Directory]::CreateDirectory($preexistingDataRoot) | Out-Null
$preexistingDataOriginal = 'E:\fixture\preexisting-data.txt'
Write-RecycleMetadataV2 -LiteralPath (Join-Path $preexistingDataRoot '$I000004.txt') -OriginalPath $preexistingDataOriginal -OriginalSize 5 -DeletedAtUtc $deletedAtUtc
[IO.File]::WriteAllBytes((Join-Path $preexistingDataRoot '$R000004.txt'), [Text.Encoding]::UTF8.GetBytes('12345'))
$preexistingDataSnapshot = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath (Join-Path $preexistingDataRoot '$R000004.txt') -Force)
$preexistingDataMatches = @(Find-NewRecycleEvidence -RecyclePath $preexistingDataRoot -EntryNamesBefore @('$R000004.txt') -NormalizedPath $preexistingDataOriginal -OperationStartedAtUtc $operationStartedAtUtc -Snapshot $preexistingDataSnapshot -Attempts 1 -DelayMilliseconds 0)
Assert-True -Condition ($preexistingDataMatches.Count -eq 0) -Message 'A pre-existing orphan $R was accepted as evidence for a new $I.'

$matchingDirectoryRoot = Join-Path $fixtureRoot 'matching-directory'
[IO.Directory]::CreateDirectory($matchingDirectoryRoot) | Out-Null
$matchingDirectoryOriginal = 'E:\fixture\matching-directory'
Write-RecycleMetadataV2 -LiteralPath (Join-Path $matchingDirectoryRoot '$I000005') -OriginalPath $matchingDirectoryOriginal -OriginalSize 0 -DeletedAtUtc $deletedAtUtc
$matchingDataDirectory = Join-Path $matchingDirectoryRoot '$R000005'
$matchingDataSubdirectory = Join-Path $matchingDataDirectory 'subdirectory'
[IO.Directory]::CreateDirectory($matchingDataSubdirectory) | Out-Null
[IO.File]::WriteAllBytes((Join-Path $matchingDataDirectory 'one.bin'), [byte[]]@(1, 2, 3))
[IO.File]::WriteAllBytes((Join-Path $matchingDataSubdirectory 'two.bin'), [byte[]]@(4, 5))
$matchingDirectorySnapshot = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $matchingDataDirectory -Force)
$matchingDirectoryMatches = @(Find-NewRecycleEvidence -RecyclePath $matchingDirectoryRoot -EntryNamesBefore @() -NormalizedPath $matchingDirectoryOriginal -OperationStartedAtUtc $operationStartedAtUtc -Snapshot $matchingDirectorySnapshot -Attempts 1 -DelayMilliseconds 0)
Assert-True -Condition ($matchingDirectoryMatches.Count -eq 1) -Message 'An exact new $I/$R directory pair was not accepted.'

$reparseDataRoot = Join-Path $fixtureRoot 'reparse-data'
[IO.Directory]::CreateDirectory($reparseDataRoot) | Out-Null
$reparseDataOriginal = 'E:\fixture\reparse-data'
Write-RecycleMetadataV2 -LiteralPath (Join-Path $reparseDataRoot '$I000006') -OriginalPath $reparseDataOriginal -OriginalSize 0 -DeletedAtUtc $deletedAtUtc
$reparseDataDirectory = Join-Path $reparseDataRoot '$R000006'
$reparseDataTarget = Join-Path $fixtureRoot ('reparse-target-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($reparseDataDirectory) | Out-Null
[IO.Directory]::CreateDirectory($reparseDataTarget) | Out-Null
New-Item -ItemType Junction -Path (Join-Path $reparseDataDirectory 'linked') -Target $reparseDataTarget | Out-Null
$reparseDataMatches = @(Find-NewRecycleEvidence -RecyclePath $reparseDataRoot -EntryNamesBefore @() -NormalizedPath $reparseDataOriginal -OperationStartedAtUtc $operationStartedAtUtc -Snapshot ([pscustomobject]@{ Type = 'Directory'; FileCount = 0L; DirectoryCount = 1L; Bytes = 0L; Fingerprint = 'fixture' }) -Attempts 1 -DelayMilliseconds 0)
Assert-True -Condition ($reparseDataMatches.Count -eq 0) -Message 'A reparse-bearing $R object was accepted or escaped evidence failure handling.'

$snapshotDriftPath = Join-Path $fixtureRoot 'snapshot-drift.bin'
[IO.File]::WriteAllBytes($snapshotDriftPath, [byte[]]@(1, 2, 3))
$snapshotBefore = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $snapshotDriftPath -Force)
[IO.File]::WriteAllBytes($snapshotDriftPath, [byte[]]@(1, 2, 3, 4))
$snapshotAfter = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $snapshotDriftPath -Force)
Assert-True -Condition (-not (Test-TargetSnapshotSame -Expected $snapshotBefore -Actual $snapshotAfter)) -Message 'Snapshot equality accepted byte drift.'

$sameSizeDriftPath = Join-Path $fixtureRoot 'same-size-drift.bin'
[IO.File]::WriteAllBytes($sameSizeDriftPath, [byte[]]@(1, 2, 3))
$sameSizeBefore = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $sameSizeDriftPath -Force)
[IO.File]::WriteAllBytes($sameSizeDriftPath, [byte[]]@(4, 5, 6))
[IO.File]::SetLastWriteTimeUtc($sameSizeDriftPath, [DateTime]::UtcNow.AddMinutes(5))
$sameSizeAfter = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $sameSizeDriftPath -Force)
Assert-True -Condition (-not (Test-TargetSnapshotSame -Expected $sameSizeBefore -Actual $sameSizeAfter)) -Message 'Snapshot equality accepted same-size metadata drift.'

$nameDriftRoot = Join-Path $fixtureRoot 'name-drift'
[IO.Directory]::CreateDirectory($nameDriftRoot) | Out-Null
[IO.File]::WriteAllBytes((Join-Path $nameDriftRoot 'before.bin'), [byte[]]@(1))
$nameDriftBefore = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $nameDriftRoot -Force)
[IO.File]::Move((Join-Path $nameDriftRoot 'before.bin'), (Join-Path $nameDriftRoot 'after.bin'))
$nameDriftAfter = Get-TargetSnapshot -TargetItem (Get-Item -LiteralPath $nameDriftRoot -Force)
Assert-True -Condition (-not (Test-TargetSnapshotSame -Expected $nameDriftBefore -Actual $nameDriftAfter)) -Message 'Snapshot equality accepted same-size relative-path drift.'

[pscustomobject]@{
    Passed = $true
    Test = 'HelperRecycleEvidence'
    FixtureRoot = $fixtureRoot
    Cases = 9
} | ConvertTo-Json -Compress
