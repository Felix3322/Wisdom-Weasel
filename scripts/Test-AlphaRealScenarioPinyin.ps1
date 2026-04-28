[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot '..\alpha_backend\config.toml'),
  [string]$DllPath = (Join-Path $PSScriptRoot '..\alpha_backend\target\release\alpha_input.dll'),
  [int]$TopN = 5
)

$ErrorActionPreference = 'Stop'

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$DllPath = [System.IO.Path]::GetFullPath($DllPath)
$DllDir = Split-Path -Parent $DllPath
$DllImportPath = $DllPath.Replace('\', '\\')
$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$AbbrevPath = Join-Path $Root 'third_party\rime_wanxiang\lua\data\abbrev.txt'
$T9AbbrevPath = Join-Path $Root 'third_party\rime_wanxiang\lua\data\t9_abbrev.txt'

if (-not (Test-Path $ConfigPath)) {
  throw "Config not found: $ConfigPath"
}
if (-not (Test-Path $DllPath)) {
  throw "DLL not found: $DllPath"
}
if (-not (Test-Path $AbbrevPath)) {
  throw "Abbrev file not found: $AbbrevPath"
}
if (-not (Test-Path $T9AbbrevPath)) {
  throw "T9 abbrev file not found: $T9AbbrevPath"
}

$source = @"
using System;
using System.Runtime.InteropServices;

public static class AlphaNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct SimilarityResult {
        public IntPtr word;
        public float score;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string lpPathName);

    [DllImport("$DllImportPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr alpha_predictive_new([MarshalAs(UnmanagedType.LPUTF8Str)] string configPath);

    [DllImport("$DllImportPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void alpha_predictive_free(IntPtr predictive);

    [DllImport("$DllImportPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern int alpha_predictive_compute_similarities_ordered(
        IntPtr predictive,
        IntPtr input,
        IntPtr[] candidates,
        int numCandidates,
        out IntPtr results);

    [DllImport("$DllImportPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void alpha_predictive_free_similarities_result(IntPtr results, int len);
}
"@

Add-Type -TypeDefinition $source -Language CSharp
[AlphaNative]::SetDllDirectory($DllDir) | Out-Null
[Environment]::CurrentDirectory = $DllDir

$DefaultContextMaxChars = 96
$DefaultRecentTailChars = 24
$DefaultUserRecordQueryWeight = 0.20
$DefaultRawContextQueryWeight = 0.60
$DefaultRecentClauseQueryWeight = 0.25
$DefaultRecentTailQueryWeight = 0.20
$DefaultAnchorQueryWeight = 0.35
$DefaultRawContextViewWeight = 0.28
$DefaultSoftCleanContextViewWeight = 0.55
$DefaultAnchoredContextViewWeight = 0.32
$DefaultDomainPreservedContextViewWeight = 0.35
$DefaultMinContextConfidence = 0.35

$ContextAnchorTokens = @('去', '和', '把', '先', '再', '下午', '上午', '今晚', '明天', '下周', '月底', '酒店', '出差', '咳嗽', '发烧', '输入法', '优化', '延迟', '发布', '考试')
$DomainPreservedPatterns = @('[A-Z]{2,}', '[A-Za-z]+\.[\w-]+', '[\w-]+\.toml', '[\w-]+\.yaml', '[\w-]+\.json', '[\w-]+\.dll', '[\w-]+\.exe')

$LeadingFillerPatterns = @(
  '^今天', '^明天', '^今晚', '^昨晚', '^上午', '^中午', '^下午', '^月底', '^这两天', '^这几天', '^最近',
  '^我想', '^想先', '^准备', '^打算', '^计划', '^先去', '^先把', '^先', '^再', '^然后', '^接着', '^继续',
  '^还得', '^还要', '^得先', '^得去', '^要先', '^要去', '^把', '^去', '^来', '^更新', '^补充', '^检查',
  '^统一', '^整理', '^处理', '^提交', '^拉', '^写', '^做', '^改', '^看'
)
$TrailingFillerPatterns = @('一下$', '一下子$', '一遍$', '看看$')
$TrailingParticlePatterns = @('了$', '吧$', '呢$', '呀$', '啊$', '吗$')
$WrapperTrimChars = @(
  '（', '）', '(', ')', '【', '】', '[', ']', '「', '」', '『', '』', '《', '》', '“', '”',
  '"', "'", '…', '—', '-'
)

function Trim-Text {
  param([string]$Text)
  if ($null -eq $Text) {
    return ''
  }
  return $Text.Trim()
}

function Get-TailText {
  param(
    [string]$Text,
    [int]$KeepChars
  )
  $Text = Trim-Text $Text
  if ($Text.Length -le $KeepChars) {
    return $Text
  }
  return $Text.Substring($Text.Length - $KeepChars)
}

function Strip-Patterns {
  param(
    [string]$Text,
    [string[]]$Patterns
  )
  $Text = Trim-Text $Text
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ''
  }

  do {
    $Changed = $false
    foreach ($Pattern in $Patterns) {
      $Updated = [regex]::Replace($Text, $Pattern, '', 1)
      if ($Updated -ne $Text) {
        $Text = Trim-Text $Updated
        $Changed = $true
      }
    }
  } while ($Changed -and $Text -ne '')

  return $Text
}

function Strip-WrapperNoise {
  param([string]$Text)
  $Text = Trim-Text $Text
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ''
  }
  return $Text.Trim($WrapperTrimChars)
}

function Get-MeaningfulContextText {
  param([string]$Text)
  $Normalized = Strip-WrapperNoise $Text
  $Normalized = [regex]::Replace($Normalized, '[\s　]+', '')
  $Normalized = Strip-Patterns $Normalized $LeadingFillerPatterns
  $Normalized = Strip-Patterns $Normalized $TrailingFillerPatterns
  $Normalized = Strip-Patterns $Normalized $TrailingParticlePatterns
  $Normalized = [regex]::Replace($Normalized, '[，,、：:；;。！？!?]', '')
  return Trim-Text $Normalized
}

function Test-LowInformationClause {
  param([string]$Text)
  $Original = Trim-Text $Text
  if ([string]::IsNullOrWhiteSpace($Original)) {
    return $true
  }

  $Meaningful = Get-MeaningfulContextText $Original
  if ([string]::IsNullOrWhiteSpace($Meaningful)) {
    return $true
  }

  if ($Meaningful.Length -le 2 -and $Meaningful -match '^[A-Za-z]+$') {
    return $true
  }
  if ($Original.Length -le 6 -and $Meaningful.Length -le 2) {
    return $true
  }
  if ($Original.Length -le 8 -and $Meaningful.Length -le 1) {
    return $true
  }
  return $false
}

function Split-Clauses {
  param([string]$Text)
  $Text = Trim-Text $Text
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @()
  }
  $Parts = [regex]::Split($Text, '[，,、：:；;。！？!?]+')
  return @($Parts | ForEach-Object { Trim-Text $_ } | Where-Object { $_ -ne '' })
}

function Compose-CleanContext {
  param(
    [string]$AnchorClause,
    [string]$RecentClause,
    [string]$MergedTail
  )
  $AnchorClause = Trim-Text $AnchorClause
  $RecentClause = Trim-Text $RecentClause
  $MergedTail = Trim-Text $MergedTail

  if ($AnchorClause -and $RecentClause) {
    if ($RecentClause.Contains($AnchorClause)) {
      return $RecentClause
    }
    if ($AnchorClause.Contains($RecentClause)) {
      return $AnchorClause
    }

    $Joiner = if ($AnchorClause -match '[，,、：:；;。！？!?]$') { '' } else { '，' }
    return Trim-Text ($AnchorClause + $Joiner + $RecentClause)
  }

  if ($RecentClause) {
    return $RecentClause
  }
  if ($MergedTail) {
    return $MergedTail
  }
  return $AnchorClause
}

function Join-NonEmptyUnique {
  param(
    [string[]]$Values,
    [string]$Separator = '，'
  )
  $Seen = @{}
  $Parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($Value in $Values) {
    $Text = Trim-Text $Value
    if ($Text -and -not $Seen.ContainsKey($Text)) {
      $Parts.Add($Text) | Out-Null
      $Seen[$Text] = $true
    }
  }
  return ($Parts -join $Separator)
}

function Get-DomainPreservedTokens {
  param([string]$Text)
  $Seen = @{}
  $Tokens = New-Object 'System.Collections.Generic.List[string]'
  foreach ($Pattern in $DomainPreservedPatterns) {
    foreach ($Match in [regex]::Matches($Text, $Pattern)) {
      $Token = Trim-Text $Match.Value
      if ($Token -and -not $Seen.ContainsKey($Token)) {
        $Tokens.Add($Token) | Out-Null
        $Seen[$Token] = $true
      }
    }
  }
  return @($Tokens)
}

function Build-AnchoredContext {
  param($Snapshot)
  $Parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($Text in @($Snapshot.anchor_clause, $Snapshot.recent_clause, $Snapshot.recent_tail)) {
    if (Trim-Text $Text) { $Parts.Add((Trim-Text $Text)) | Out-Null }
  }
  $Source = Trim-Text $Snapshot.merged_tail
  foreach ($Token in $ContextAnchorTokens) {
    if ($Source.Contains($Token)) { $Parts.Add($Token) | Out-Null }
  }
  return Join-NonEmptyUnique -Values @($Parts)
}

function Build-DomainPreservedContext {
  param($Snapshot)
  $Source = Trim-Text $Snapshot.merged_tail
  $Tokens = Get-DomainPreservedTokens $Source
  return Join-NonEmptyUnique -Values @($Snapshot.clean_context, $Tokens, $Snapshot.anchored_context)
}

function Get-ContextConfidence {
  param($Snapshot)
  $Confidence = 0.0
  if ($Snapshot.anchor_informative) { $Confidence += 0.45 }
  if ($Snapshot.recent_informative) { $Confidence += 0.35 }
  if ($Snapshot.recent_tail_informative) { $Confidence += 0.10 }

  $EffectiveLength = (Trim-Text $Snapshot.clean_context).Length
  if ($EffectiveLength -ge 12) {
    $Confidence += 0.20
  } elseif ($EffectiveLength -ge 8) {
    $Confidence += 0.15
  } elseif ($EffectiveLength -ge 4) {
    $Confidence += 0.08
  }

  if ($Snapshot.anchor_informative -and $Snapshot.recent_informative) {
    $Confidence += 0.10
  }
  return [Math]::Min($Confidence, 1.0)
}

function New-OldSnapshot {
  param([string]$ContextText)
  $MergedTail = Get-TailText $ContextText $DefaultContextMaxChars
  $Clauses = Split-Clauses $ContextText
  $RecentClause = if ($Clauses.Count -ge 1) { $Clauses[$Clauses.Count - 1] } else { '' }
  $AnchorClause = if ($Clauses.Count -ge 2) { $Clauses[$Clauses.Count - 2] } else { '' }
  $RecentTail = Get-TailText $ContextText $DefaultRecentTailChars
  $CleanContext = Compose-CleanContext $AnchorClause $RecentClause $MergedTail

  return [PSCustomObject]@{
    anchor_clause = $AnchorClause
    recent_clause = $RecentClause
    recent_tail = $RecentTail
    merged_tail = $MergedTail
    clean_context = $CleanContext
  }
}

function New-NewSnapshot {
  param([string]$ContextText)
  $MergedTail = Get-TailText $ContextText $DefaultContextMaxChars
  $Clauses = Split-Clauses $ContextText
  $RecentClause = if ($Clauses.Count -ge 1) { $Clauses[$Clauses.Count - 1] } else { '' }
  $AnchorClause = if ($Clauses.Count -ge 2) { $Clauses[$Clauses.Count - 2] } else { '' }
  $RecentTail = Get-TailText $ContextText $DefaultRecentTailChars

  $Snapshot = [PSCustomObject]@{
    anchor_clause = $AnchorClause
    recent_clause = $RecentClause
    recent_tail = $RecentTail
    merged_tail = $MergedTail
    clean_context = ''
    raw_context = $MergedTail
    soft_clean_context = ''
    anchored_context = ''
    domain_preserved_context = ''
    anchor_informative = ($AnchorClause -ne '' -and -not (Test-LowInformationClause $AnchorClause))
    recent_informative = ($RecentClause -ne '' -and -not (Test-LowInformationClause $RecentClause))
    recent_tail_informative = ($RecentTail -ne '' -and -not (Test-LowInformationClause $RecentTail))
    merged_tail_informative = ($MergedTail -ne '' -and -not (Test-LowInformationClause $MergedTail))
    context_confidence = 0.0
  }

  $EffectiveAnchor = if ($Snapshot.anchor_informative) { $Snapshot.anchor_clause } else { '' }
  $EffectiveRecent = if ($Snapshot.recent_informative) { $Snapshot.recent_clause } else { '' }
  $EffectiveTail = ''
  if (-not $EffectiveAnchor -and -not $EffectiveRecent) {
    if ($Snapshot.recent_tail_informative) {
      $EffectiveTail = $Snapshot.recent_tail
    } elseif ($Snapshot.merged_tail_informative) {
      $EffectiveTail = $Snapshot.merged_tail
    }
  }

  $Snapshot.clean_context = Compose-CleanContext $EffectiveAnchor $EffectiveRecent $EffectiveTail
  $Snapshot.soft_clean_context = $Snapshot.clean_context
  $Snapshot.anchored_context = Build-AnchoredContext $Snapshot
  $Snapshot.domain_preserved_context = Build-DomainPreservedContext $Snapshot
  $Snapshot.context_confidence = Get-ContextConfidence $Snapshot
  return $Snapshot
}

function Add-Variant {
  param(
    [System.Collections.Generic.List[object]]$Variants,
    [hashtable]$Seen,
    [string]$Label,
    [string]$Text,
    [double]$Weight
  )
  $Text = Trim-Text $Text
  if (-not $Text -or $Weight -le 0) {
    return
  }
  if ($Seen.ContainsKey($Text)) {
    $Seen[$Text].weight = [Math]::Max([double]$Seen[$Text].weight, $Weight)
    return
  }
  $Variant = [PSCustomObject]@{
    label = $Label
    text = $Text
    weight = $Weight
  }
  $Variants.Add($Variant) | Out-Null
  $Seen[$Text] = $Variant
}

function Normalize-VariantWeights {
  param([System.Collections.Generic.List[object]]$Variants)
  $Total = 0.0
  foreach ($Variant in $Variants) {
    $Total += [Math]::Max([double]$Variant.weight, 0.0)
  }
  if ($Total -le 0) {
    return @($Variants)
  }
  foreach ($Variant in $Variants) {
    $Variant.weight = [double]$Variant.weight / $Total
  }
  return @($Variants)
}

function Build-OldQueryVariants {
  param($Snapshot)
  $Variants = New-Object 'System.Collections.Generic.List[object]'
  $Seen = @{}
  $CleanContext = Trim-Text $Snapshot.soft_clean_context
  $RawContext = Trim-Text $Snapshot.raw_context
  $AnchoredContext = Trim-Text $Snapshot.anchored_context
  $DomainContext = Trim-Text $Snapshot.domain_preserved_context

  Add-Variant $Variants $Seen 'raw_context' $RawContext $DefaultRawContextViewWeight
  Add-Variant $Variants $Seen 'user_record_context' ($(if ($CleanContext) { "用户输入记录：$CleanContext" } else { '' })) $DefaultUserRecordQueryWeight
  Add-Variant $Variants $Seen 'soft_clean_context' $CleanContext $DefaultSoftCleanContextViewWeight
  if ($AnchoredContext -and $AnchoredContext -ne $CleanContext) {
    Add-Variant $Variants $Seen 'anchored_context' $AnchoredContext $DefaultAnchoredContextViewWeight
  }
  if ($DomainContext -and $DomainContext -ne $CleanContext -and $DomainContext -ne $AnchoredContext) {
    Add-Variant $Variants $Seen 'domain_preserved_context' $DomainContext $DefaultDomainPreservedContextViewWeight
  }

  $RecentTail = Trim-Text $Snapshot.recent_tail
  if ($RecentTail -and $RecentTail -ne $CleanContext) {
    Add-Variant $Variants $Seen 'recent_tail_context' "最近输入片段：$RecentTail" $DefaultRecentTailQueryWeight
  }

  $AnchorClause = Trim-Text $Snapshot.anchor_clause
  if ($AnchorClause -and $AnchorClause -ne $CleanContext -and $AnchorClause.Length -ge 4) {
    Add-Variant $Variants $Seen 'anchor_clause' $AnchorClause $DefaultAnchorQueryWeight
  }

  return Normalize-VariantWeights $Variants
}

function Build-NewQueryVariants {
  param($Snapshot)
  $Variants = New-Object 'System.Collections.Generic.List[object]'
  $Seen = @{}
  $CleanContext = Trim-Text $Snapshot.clean_context

  Add-Variant $Variants $Seen 'user_record_context' ($(if ($CleanContext) { "用户输入记录：$CleanContext" } else { '' })) $DefaultUserRecordQueryWeight
  Add-Variant $Variants $Seen 'clean_context' $CleanContext $DefaultRawContextQueryWeight

  $RecentClause = Trim-Text $Snapshot.recent_clause
  if ($Snapshot.recent_informative -and $RecentClause -and $RecentClause -ne $CleanContext) {
    Add-Variant $Variants $Seen 'recent_clause_context' $RecentClause $DefaultRecentClauseQueryWeight
  }

  $RecentTail = Trim-Text $Snapshot.recent_tail
  if ($Snapshot.recent_tail_informative -and $RecentTail -and $RecentTail -ne $CleanContext) {
    Add-Variant $Variants $Seen 'recent_tail_context' "最近输入片段：$RecentTail" $DefaultRecentTailQueryWeight
  }

  $AnchorClause = Trim-Text $Snapshot.anchor_clause
  if ($Snapshot.anchor_informative -and $AnchorClause -and $AnchorClause -ne $CleanContext -and $AnchorClause.Length -ge 4) {
    Add-Variant $Variants $Seen 'anchor_clause' $AnchorClause $DefaultAnchorQueryWeight
  }

  return Normalize-VariantWeights $Variants
}

function New-Utf8Pointer {
  param([string]$Text)
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text + [char]0)
  $Ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes.Length)
  [System.Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $Ptr, $Bytes.Length)
  return $Ptr
}

function Invoke-AlphaSimilarity {
  param(
    [IntPtr]$Handle,
    [string]$Context,
    [string[]]$Candidates
  )

  $InputPtr = [IntPtr]::Zero
  $CandidatePtrs = New-Object System.IntPtr[] $Candidates.Count
  $ResultPtr = [IntPtr]::Zero
  $Count = 0

  try {
    $InputPtr = New-Utf8Pointer $Context
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
      $CandidatePtrs[$i] = New-Utf8Pointer $Candidates[$i]
    }

    $Count = [AlphaNative]::alpha_predictive_compute_similarities_ordered(
      $Handle,
      $InputPtr,
      $CandidatePtrs,
      $Candidates.Count,
      [ref]$ResultPtr
    )
    if ($Count -lt 0) {
      throw 'alpha_predictive_compute_similarities_ordered failed'
    }

    $Rows = New-Object 'System.Collections.Generic.List[object]'
    $StructSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][AlphaNative+SimilarityResult])
    for ($i = 0; $i -lt $Count; $i++) {
      $ItemPtr = [IntPtr]::Add($ResultPtr, $i * $StructSize)
      $Item = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
        $ItemPtr,
        [type][AlphaNative+SimilarityResult]
      )
      $Rows.Add([PSCustomObject]@{
          Text = [System.Runtime.InteropServices.Marshal]::PtrToStringUTF8($Item.word)
          Score = [double]$Item.score
        }) | Out-Null
    }
    return $Rows.ToArray()
  }
  finally {
    if ($ResultPtr -ne [IntPtr]::Zero -and $Count -gt 0) {
      [AlphaNative]::alpha_predictive_free_similarities_result($ResultPtr, $Count)
    }
    if ($InputPtr -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::FreeHGlobal($InputPtr)
    }
    foreach ($Ptr in $CandidatePtrs) {
      if ($Ptr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($Ptr)
      }
    }
  }
}

function Invoke-WeightedRanking {
  param(
    [IntPtr]$Handle,
    [object[]]$Variants,
    [string[]]$Candidates
  )

  $Scores = @{}
  for ($i = 0; $i -lt $Candidates.Count; $i++) {
    $Scores[$Candidates[$i]] = 0.0
  }

  foreach ($Variant in $Variants) {
    $Rows = Invoke-AlphaSimilarity -Handle $Handle -Context $Variant.text -Candidates $Candidates
    $RowMap = @{}
    foreach ($Row in $Rows) {
      if (-not $RowMap.ContainsKey($Row.Text)) {
        $RowMap[$Row.Text] = $Row.Score
      }
    }
    foreach ($Candidate in $Candidates) {
      $CandidateScore = if ($RowMap.ContainsKey($Candidate)) { [double]$RowMap[$Candidate] } else { 0.0 }
      $Scores[$Candidate] += ([double]$Variant.weight) * $CandidateScore
    }
  }

  return @($Candidates | ForEach-Object {
      [PSCustomObject]@{
        Text = $_
        Score = [Math]::Round([double]$Scores[$_], 4)
      }
    } | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { [array]::IndexOf($Candidates, $_.Text) }; Descending = $false })
}

function New-FallbackRanking {
  param([string[]]$Candidates)
  return @($Candidates | ForEach-Object { [PSCustomObject]@{ Text = $_; Score = 0.0 } })
}

function Get-Top1 {
  param([object[]]$Rows)
  if ($Rows.Count -gt 0) {
    return $Rows[0].Text
  }
  return ''
}

function Format-TopPreview {
  param(
    [object[]]$Rows,
    [int]$Count
  )
  return (($Rows | Select-Object -First $Count | ForEach-Object {
        '{0}:{1}' -f $_.Text, ([Math]::Round([double]$_.Score, 4))
      }) -join ' | ')
}

function Get-Rank {
  param(
    [object[]]$Rows,
    [string]$Target
  )
  for ($i = 0; $i -lt $Rows.Count; $i++) {
    if ($Rows[$i].Text -eq $Target) {
      return $i + 1
    }
  }
  return -1
}

function Get-CodeCandidates {
  param(
    [string]$Code,
    [string]$Path
  )
  $Line = Select-String -Path $Path -Pattern ("^{0}`t" -f [regex]::Escape($Code)) | Select-Object -First 1
  if (-not $Line) {
    return @()
  }
  $Parts = $Line.Line -split "`t", 2
  if ($Parts.Count -lt 2) {
    return @()
  }
  return @($Parts[1] -split '\|' | ForEach-Object { Trim-Text $_ } | Where-Object { $_ -ne '' })
}

function Merge-Candidates {
  param($Scenario)
  $Ordered = New-Object 'System.Collections.Generic.List[string]'
  $Seen = @{}

  foreach ($Path in @($AbbrevPath, $T9AbbrevPath)) {
    foreach ($Candidate in (Get-CodeCandidates -Code $Scenario.Code -Path $Path)) {
      if (-not $Seen.ContainsKey($Candidate)) {
        $Ordered.Add($Candidate) | Out-Null
        $Seen[$Candidate] = $true
      }
    }
  }

  foreach ($Candidate in $Scenario.Extras) {
    if (-not $Seen.ContainsKey($Candidate)) {
      $Ordered.Add($Candidate) | Out-Null
      $Seen[$Candidate] = $true
    }
  }

  if (-not $Seen.ContainsKey($Scenario.Target)) {
    $Ordered.Add($Scenario.Target) | Out-Null
  }

  return @($Ordered)
}

$Scenarios = @(
  [PSCustomObject]@{
    Code = 'fx'
    Context = '马上要考试了，我需要开始'
    Target = '复习'
    Extras = @()
  },
  [PSCustomObject]@{
    Code = 'jp'
    Context = '下周要去杭州出差，先把酒店和'
    Target = '机票'
    Extras = @()
  },
  [PSCustomObject]@{
    Code = 'bg'
    Context = '明天要发布新版本，先把发布说明和'
    Target = '变更日志'
    Extras = @()
  },
  [PSCustomObject]@{
    Code = 'zc'
    Context = '明天要上台主持活动，今晚把'
    Target = '主持词'
    Extras = @('支持')
  },
  [PSCustomObject]@{
    Code = 'yy'
    Context = '这两天一直咳嗽发烧，下午得去'
    Target = '医院'
    Extras = @()
  },
  [PSCustomObject]@{
    Code = 'zt'
    Context = '老师说明天考高数，我打算先做几套'
    Target = '真题'
    Extras = @('状态')
  },
  [PSCustomObject]@{
    Code = 'cp'
    Context = '今晚继续优化输入法 DLL 的'
    Target = '重排延迟'
    Extras = @()
  }
)

$Predictive = [AlphaNative]::alpha_predictive_new($ConfigPath)
if ($Predictive -eq [IntPtr]::Zero) {
  throw 'alpha_predictive_new failed'
}

try {
  Write-Host 'Alpha same-pinyin real-scenario comparison'
  Write-Host ("date={0}" -f (Get-Date -Format 'yyyy-MM-dd'))
  Write-Host ("config={0}" -f $ConfigPath)
  Write-Host ("dll={0}" -f $DllPath)
  Write-Host ''

  $Summary = New-Object 'System.Collections.Generic.List[object]'

  foreach ($Scenario in $Scenarios) {
    $Candidates = Merge-Candidates $Scenario
    $OldSnapshot = New-OldSnapshot $Scenario.Context
    $NewSnapshot = New-NewSnapshot $Scenario.Context
    $OldVariants = Build-OldQueryVariants $OldSnapshot
    $NewVariants = Build-NewQueryVariants $NewSnapshot

    $OldRanking = Invoke-WeightedRanking -Handle $Predictive -Variants $OldVariants -Candidates $Candidates
    $ScoreStatus = 'valid'
    $RawScoreAvailable = $true
    $NewRanking = if ($NewVariants.Count -le 0) {
      $ScoreStatus = 'unavailable'
      $RawScoreAvailable = $false
      New-FallbackRanking -Candidates $Candidates
    } else {
      $Rows = Invoke-WeightedRanking -Handle $Predictive -Variants $NewVariants -Candidates $Candidates
      $HasSignal = $false
      foreach ($Row in $Rows) {
        if ([Math]::Abs([double]$Row.Score) -gt 0.000000001) {
          $HasSignal = $true
          break
        }
      }
      if (-not $HasSignal) {
        $ScoreStatus = 'fallback'
      } elseif ($NewSnapshot.context_confidence -lt $DefaultMinContextConfidence) {
        $ScoreStatus = 'abstain'
      }
      $Rows
    }

    $TargetInjected = -not ((Get-CodeCandidates -Code $Scenario.Code -Path $AbbrevPath) -contains $Scenario.Target)
    $OldRank = Get-Rank -Rows $OldRanking -Target $Scenario.Target
    $NewRank = Get-Rank -Rows $NewRanking -Target $Scenario.Target
    $RawTop1 = if ($RawScoreAvailable) { Get-Top1 -Rows $NewRanking } else { '' }
    $GuardedTop1 = Get-Top1 -Rows $NewRanking

    Write-Host ("[{0}] context={1}" -f $Scenario.Code, $Scenario.Context)
    Write-Host ("  target={0} injected_into_same_code_pool={1}" -f $Scenario.Target, $TargetInjected)
    Write-Host ("  pool={0}" -f (($Candidates -join ' | ')))
    Write-Host ("  old_clean={0}" -f $OldSnapshot.clean_context)
    Write-Host ("  new_clean={0}" -f $NewSnapshot.clean_context)
    Write-Host ("  context_views raw={0} | soft={1} | anchored={2} | domain={3}" -f $NewSnapshot.raw_context, $NewSnapshot.soft_clean_context, $NewSnapshot.anchored_context, $NewSnapshot.domain_preserved_context)
    Write-Host ("  new_confidence={0}" -f ([Math]::Round([double]$NewSnapshot.context_confidence, 2)))
    Write-Host ("  score_status={0} raw_score_available={1}" -f $ScoreStatus, $RawScoreAvailable)
    Write-Host ("  old_top{0}={1}" -f $TopN, (Format-TopPreview -Rows $OldRanking -Count $TopN))
    Write-Host ("  new_top{0}={1}" -f $TopN, (Format-TopPreview -Rows $NewRanking -Count $TopN))
    Write-Host ("  raw_top1={0} guarded_top1={1}" -f $RawTop1, $GuardedTop1)
    Write-Host ("  rank_change={0}->{1}" -f $OldRank, $NewRank)
    Write-Host ''

    $Summary.Add([PSCustomObject]@{
        code = $Scenario.Code
        target = $Scenario.Target
        injected = $TargetInjected
        old_rank = $OldRank
        new_rank = $NewRank
        new_confidence = [Math]::Round([double]$NewSnapshot.context_confidence, 2)
        score_status = $ScoreStatus
        raw_score_available = $RawScoreAvailable
        old_top1 = Get-Top1 -Rows $OldRanking
        raw_top1 = $RawTop1
        guarded_top1 = $GuardedTop1
      }) | Out-Null
  }

  Write-Host 'summary:'
  $Summary | Format-Table -AutoSize
  $ValidCount = @($Summary | Where-Object { $_.score_status -eq 'valid' }).Count
  $FallbackCount = @($Summary | Where-Object { $_.score_status -eq 'fallback' }).Count
  $SkippedCount = @($Summary | Where-Object { $_.score_status -eq 'skipped' }).Count
  $AbstainCount = @($Summary | Where-Object { $_.score_status -eq 'abstain' }).Count
  $UnavailableCount = @($Summary | Where-Object { $_.score_status -eq 'unavailable' }).Count
  $LowConfidenceCount = @($Summary | Where-Object { $_.new_confidence -lt $DefaultMinContextConfidence }).Count
  Write-Host ''
  Write-Host ("valid_cases={0}/{1}" -f $ValidCount, $Summary.Count)
  Write-Host ("fallback_case_count={0}" -f $FallbackCount)
  Write-Host ("abstain_case_count={0}" -f $AbstainCount)
  Write-Host ("low_context_confidence_case_count={0}" -f $LowConfidenceCount)
  Write-Host ("score_unavailable_case_count={0}" -f ($SkippedCount + $UnavailableCount))
}
finally {
  if ($Predictive -ne [IntPtr]::Zero) {
    [AlphaNative]::alpha_predictive_free($Predictive)
  }
}
