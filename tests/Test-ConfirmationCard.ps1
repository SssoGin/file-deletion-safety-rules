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

function Read-StrictUtf8Text {
    param([Parameter(Mandatory)][string] $LiteralPath)

    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
}

function Assert-Matches {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Message
    )

    Assert-True -Condition ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) -Message $Message
}

$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$policyText = Read-StrictUtf8Text -LiteralPath (Join-Path $packageRoot 'policy\file-deletion-safety.md')
$englishReadme = Read-StrictUtf8Text -LiteralPath (Join-Path $packageRoot 'README.md')
$chineseReadme = Read-StrictUtf8Text -LiteralPath (Join-Path $packageRoot 'README.zh-CN.md')

$sectionMatch = [regex]::Match(
    $policyText,
    '(?s)### 2\.2 固定“清理确认”卡\r?\n(?<Body>.*?)\r?\n### 2\.3 '
)
Assert-True -Condition $sectionMatch.Success -Message 'RED: policy has no dedicated fixed cleanup-confirmation-card contract.'
$cardSection = $sectionMatch.Groups['Body'].Value

$fieldLabels = @(
    '清理对象',
    '位置',
    '清理范围',
    '内容',
    '占用空间',
    '清理原因',
    '清理方式',
    '安全边界',
    '清理结果',
    '恢复方式'
)
$sectionLines = @($cardSection -split '\r?\n')
$tableHeaderIndex = -1
for ($lineIndex = 0; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
    if ([regex]::IsMatch($sectionLines[$lineIndex], '^\s*\|\s*项目\s*\|\s*内容\s*\|\s*$')) {
        $tableHeaderIndex = $lineIndex
        break
    }
}
Assert-True -Condition ($tableHeaderIndex -ge 0) -Message 'RED: cleanup confirmation is not defined as the required two-column Markdown table.'

$tableLines = @()
for ($lineIndex = $tableHeaderIndex; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
    if (-not [regex]::IsMatch($sectionLines[$lineIndex], '^\s*\|.*\|\s*$')) { break }
    $tableLines += $sectionLines[$lineIndex]
}
Assert-True -Condition ($tableLines.Count -eq 12) -Message 'RED: cleanup card table must contain one header, one separator, and exactly ten data rows.'
Assert-True -Condition ([regex]::IsMatch($tableLines[1], '^\s*\|\s*:?-{3,}:?\s*\|\s*:?-{3,}:?\s*\|\s*$')) -Message 'RED: cleanup card table must have a valid two-column Markdown separator.'

$templateLabels = @($tableLines | Select-Object -Skip 2 | ForEach-Object {
    $labelMatch = [regex]::Match($_, '^\|\s*(?<Label>[^|]+?)\s*\|')
    if ($labelMatch.Success) { $labelMatch.Groups['Label'].Value }
})
Assert-True -Condition (($templateLabels -join '|') -ceq ($fieldLabels -join '|')) -Message 'RED: cleanup card table must contain exactly ten fixed rows in the required order.'
Assert-True -Condition (-not [regex]::IsMatch($cardSection, '(?s)```.*?\| 项目 \| 内容 \|.*?```')) -Message 'RED: cleanup card table must render directly and must not be wrapped in a code fence.'

Assert-Matches -Text $cardSection -Pattern '三种模式.*小范围、中范围和大范围.*同一.*十行.*两列.*Markdown.*表格' -Message 'RED: the fixed table is not required for every mode and cleanup size.'
Assert-True -Condition (-not $cardSection.Contains('必须以 `### 清理确认` 开始')) -Message 'RED: policy hard-codes an unapproved Markdown heading level.'
Assert-Matches -Text $cardSection -Pattern '不得.*冒号列表' -Message 'RED: policy still permits the non-card colon-list rendering.'
Assert-Matches -Text $cardSection -Pattern '确认指令.*表格之后.*不属于.*卡片' -Message 'RED: confirmation prompt placement can still mutate the fixed card.'
Assert-Matches -Text $cardSection -Pattern '顶层目标.*绝对路径.*后代.*汇总' -Message 'RED: top-level path display and descendant aggregation are not defined.'
Assert-Matches -Text $cardSection -Pattern '不得创建.*本地清单' -Message 'RED: the policy still permits per-cleanup local manifest files.'
Assert-Matches -Text $cardSection -Pattern '不透明.*快照 ID' -Message 'RED: opaque snapshot IDs can still replace useful confirmation content.'
Assert-Matches -Text $cardSection -Pattern '上下文.*快照.*无法.*重新.*确认' -Message 'RED: snapshot loss after context change does not force a new confirmation.'
Assert-Matches -Text $cardSection -Pattern '多个本地卷.*多个模式.*按.*卷.*模式.*拆' -Message 'RED: large mixed cleanups are not split by volume and mode.'
Assert-Matches -Text $cardSection -Pattern '清理结果.*执行前.*预计.*执行后.*实际' -Message 'RED: expected and actual cleanup results are not distinguished.'
Assert-Matches -Text $cardSection -Pattern '恢复方式.*第 10.*隔离.*回收站.*备份.*Git.*无' -Message 'RED: the fixed recovery row does not cover the approved recovery and reconstruction sources.'

$modeContracts = @(
    [pscustomobject]@{ Size = '小范围'; Mode = '模式 A'; Pattern = '模式 A.*同卷隔离.*可恢复.*不释放空间' },
    [pscustomobject]@{ Size = '中范围'; Mode = '模式 B'; Pattern = '模式 B.*自动回收站.*可恢复.*不释放空间.*不清空回收站' },
    [pscustomobject]@{ Size = '大范围'; Mode = '模式 C'; Pattern = '模式 C.*永久删除.*不进入回收站.*无法由 Agent 恢复' }
)
foreach ($modeContract in $modeContracts) {
    Assert-Matches -Text $cardSection -Pattern $modeContract.Pattern -Message "RED: $($modeContract.Size) $($modeContract.Mode) card outcome is incomplete."
}

Assert-Matches -Text $cardSection -Pattern 'Junction.*真实目标.*清理.*独立.*位置' -Message 'RED: a Junction target selected for cleanup is not promoted to an explicit top-level target.'
Assert-Matches -Text $cardSection -Pattern '真实目标.*顶层目标.*完整覆盖.*不得重复.*位置.*计数' -Message 'RED: an in-scope Junction target is duplicated as an ancestor/descendant target.'
Assert-Matches -Text $cardSection -Pattern '共享.*Junction.*只删除.*Junction.*真实目标.*保留' -Message 'RED: the shared-target Junction branch is not explicit.'
Assert-Matches -Text $cardSection -Pattern '用途不明.*Junction.*停止.*不得.*确认' -Message 'RED: an unknown-purpose Junction can still reach confirmation.'
Assert-Matches -Text $cardSection -Pattern 'Junction.*数量.*用途.*不展开.*对应' -Message 'RED: the normal card has no concise Junction summary rule.'
Assert-Matches -Text $cardSection -Pattern '模式 B.*Junction.*不可用.*不得.*确认卡' -Message 'RED: the policy allows a Junction-bearing target to reach an unsupported Recycle Bin confirmation.'

Assert-Matches -Text $chineseReadme -Pattern '固定十行.*两列 Markdown 表格.*清理确认' -Message 'RED: Chinese README does not explain the fixed ten-row table card.'
Assert-Matches -Text $chineseReadme -Pattern '不生成.*本地清单' -Message 'RED: Chinese README does not explain the no-local-manifest rule.'
Assert-Matches -Text $chineseReadme -Pattern '(?=.*模式 B)(?=.*Junction)(?=.*不可用)' -Message 'RED: Chinese README omits the Recycle Bin Junction boundary.'
Assert-Matches -Text $englishReadme -Pattern 'fixed ten-row.*two-column Markdown table.*cleanup confirmation' -Message 'RED: English README does not explain the fixed ten-row table card.'
Assert-Matches -Text $englishReadme -Pattern 'does not create.*local manifest' -Message 'RED: English README does not explain the no-local-manifest rule.'
Assert-Matches -Text $englishReadme -Pattern '(?=.*Mode B)(?=.*Junction)(?=.*unavailable)' -Message 'RED: English README omits the Recycle Bin Junction boundary.'

[pscustomobject]@{
    Passed = $true
    Test = 'ConfirmationCardContract'
    FixedFieldCount = $fieldLabels.Count
    ScopeContract = 'AllSizesAndModesUseTheFixedCard'
    ModeOutcomeContracts = @('Quarantine', 'RecycleBin', 'Permanent')
    JunctionBranches = @('ExternalTargetAlsoDeleted', 'InScopeTargetCovered', 'SharedTargetPreserved', 'UnknownPurposeStops')
} | ConvertTo-Json -Depth 4 -Compress
