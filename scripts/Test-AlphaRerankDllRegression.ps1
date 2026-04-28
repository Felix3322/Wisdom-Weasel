[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot '..\alpha_backend\config.toml'),
  [string]$DllPath = (Join-Path $PSScriptRoot '..\alpha_backend\target\release\alpha_input.dll'),
  [int]$TopN = 3,
  [switch]$IgnoreFailures
)

$ErrorActionPreference = 'Stop'

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$DllPath = [System.IO.Path]::GetFullPath($DllPath)
$DllDir = Split-Path -Parent $DllPath
$DllImportPath = $DllPath.Replace('\', '\\')

if (-not (Test-Path $ConfigPath)) {
  throw "Config not found: $ConfigPath"
}
if (-not (Test-Path $DllPath)) {
  throw "DLL not found: $DllPath"
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

function New-Utf8Pointer {
  param([string]$Text)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text + [char]0)
  $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
  [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $bytes.Length)
  return $ptr
}

function Invoke-AlphaRegressionCase {
  param(
    [IntPtr]$Handle,
    [string]$Context,
    [string[]]$Candidates
  )

  $inputPtr = [IntPtr]::Zero
  $candidatePtrs = New-Object System.IntPtr[] $Candidates.Count
  $resultPtr = [IntPtr]::Zero
  $count = 0

  try {
    $inputPtr = New-Utf8Pointer $Context
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
      $candidatePtrs[$i] = New-Utf8Pointer $Candidates[$i]
    }

    $count = [AlphaNative]::alpha_predictive_compute_similarities_ordered(
      $Handle,
      $inputPtr,
      $candidatePtrs,
      $Candidates.Count,
      [ref]$resultPtr
    )

    if ($count -lt 0) {
      throw 'alpha_predictive_compute_similarities_ordered failed'
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $structSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][AlphaNative+SimilarityResult])
    for ($i = 0; $i -lt $count; $i++) {
      $itemPtr = [IntPtr]::Add($resultPtr, $i * $structSize)
      $item = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
        $itemPtr,
        [type][AlphaNative+SimilarityResult]
      )
      $text = [System.Runtime.InteropServices.Marshal]::PtrToStringUTF8($item.word)
      $rows.Add([PSCustomObject]@{
          Rank = $i + 1
          Text = $text
          Score = [Math]::Round([double]$item.score, 4)
        }) | Out-Null
    }
    return $rows
  }
  finally {
    if ($resultPtr -ne [IntPtr]::Zero -and $count -gt 0) {
      [AlphaNative]::alpha_predictive_free_similarities_result($resultPtr, $count)
    }
    if ($inputPtr -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::FreeHGlobal($inputPtr)
    }
    foreach ($ptr in $candidatePtrs) {
      if ($ptr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
      }
    }
  }
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

function Get-CaseCategory {
  param([object]$Scenario)
  if ($Scenario.PSObject.Properties.Name -contains 'Category' -and $Scenario.Category) {
    return [string]$Scenario.Category
  }
  if ($Scenario.Expected.Length -ge 3) {
    return 'content_word'
  }
  return 'short_ambiguity'
}

$scenarios = @(
  [PSCustomObject]@{
    Name = 'security_audit'
    Expected = '审计日志'
    Context = '昨晚检测到异常登录，先去拉一下'
    Candidates = @('访问日志', '审计日志', '错误码表', '会议纪要', '发布计划', '采购审批')
    Category = 'content_word'
    AddedOn = '2026-04-18'
  },
  [PSCustomObject]@{
    Name = 'finance_board'
    Expected = '现金流预测'
    Context = '月底给董事会汇报之前，先更新一下'
    Candidates = @('现金流预测', '培训安排', '客户回访', '会议纪要', '采购计划', '工位调整')
    Category = 'content_word'
    AddedOn = '2026-04-18'
  },
  [PSCustomObject]@{
    Name = 'legal_contract'
    Expected = '违约责任'
    Context = '法务说合作协议里还得补充'
    Candidates = @('违约责任', '活动方案', '合作周期', '发版节奏', '参会名单', '预算申请')
    Category = 'content_word'
    AddedOn = '2026-04-18'
  },
  [PSCustomObject]@{
    Name = 'medical_visit'
    Expected = '呼吸内科'
    Context = '连续咳嗽发烧三天，下午准备去'
    Candidates = @('呼吸内科', '心理咨询', '住院押金', '医保报销', '体检中心', '康复训练')
    Category = 'content_word'
    AddedOn = '2026-04-18'
  },
  [PSCustomObject]@{
    Name = 'research_seed'
    Expected = '随机种子'
    Context = '论文实验结果波动很大，我想先检查'
    Candidates = @('随机种子', '市场份额', '回归报告', '会议纪要', '变量命名', '采购流程')
    Category = 'content_word'
    AddedOn = '2026-04-18'
  },
  [PSCustomObject]@{
    Name = 'frontend_hierarchy'
    Expected = '视觉层级'
    Context = '首页首屏看着很乱，先统一一下'
    Candidates = @('视觉层级', '代码注释', '数据权限', '审批流程', '字段映射', '预算科目')
    Category = 'content_word'
    AddedOn = '2026-04-18'
  }
)

$predictive = [AlphaNative]::alpha_predictive_new($ConfigPath)
if ($predictive -eq [IntPtr]::Zero) {
  throw 'alpha_predictive_new failed'
}

try {
  Write-Host 'Alpha DLL harder-case regression'
  Write-Host ("date={0}" -f (Get-Date -Format 'yyyy-MM-dd'))
  Write-Host ("config={0}" -f $ConfigPath)
  Write-Host ("dll={0}" -f $DllPath)
  Write-Host ("cases={0}" -f $scenarios.Count)
  Write-Host ''

  $failures = New-Object System.Collections.Generic.List[object]
  $caseRows = New-Object System.Collections.Generic.List[object]
  $passCount = 0

  foreach ($scenario in $scenarios) {
    $rows = Invoke-AlphaRegressionCase -Handle $predictive -Context $scenario.Context -Candidates $scenario.Candidates
    $top1 = if ($rows.Count -gt 0) { $rows[0].Text } else { '' }
    $rank = Get-Rank -Rows $rows -Target $scenario.Expected
    $top3Hit = $rank -ge 1 -and $rank -le 3
    $mrr = if ($rank -gt 0) { [Math]::Round(1.0 / [double]$rank, 4) } else { 0.0 }
    $scoreStatus = if ($rows.Count -le 0) { 'unavailable' } else { 'valid' }
    $category = Get-CaseCategory -Scenario $scenario
    $status = if ($top1 -eq $scenario.Expected) { 'PASS' } else { 'FAIL' }
    $topPreview = ($rows | Select-Object -First ([Math]::Max($TopN, 1)) | ForEach-Object {
        '{0}:{1}' -f $_.Text, $_.Score
      }) -join ' | '

    Write-Host ("[{0}] {1}" -f $status, $scenario.Name)
    Write-Host ("  expected={0}" -f $scenario.Expected)
    Write-Host ("  category={0} score_status={1}" -f $category, $scoreStatus)
    Write-Host ("  top1={0}" -f $top1)
    Write-Host ("  rank={0} top3_hit={1} mrr={2}" -f $rank, $top3Hit, $mrr)
    Write-Host ("  top{0}={1}" -f ([Math]::Max($TopN, 1)), $topPreview)

    $caseRows.Add([PSCustomObject]@{
        name = $scenario.Name
        category = $category
        score_status = $scoreStatus
        expected = $scenario.Expected
        top1 = $top1
        rank = $rank
        top1_hit = $top1 -eq $scenario.Expected
        top3_hit = $top3Hit
        mrr = $mrr
      }) | Out-Null

    if ($status -eq 'PASS') {
      $passCount++
    }
    else {
      $failures.Add([PSCustomObject]@{
          name = $scenario.Name
          expected = $scenario.Expected
          top1 = $top1
          top_preview = $topPreview
          added_on = $scenario.AddedOn
        }) | Out-Null
    }
  }

  Write-Host ''
  Write-Host ("summary pass={0}/{1}" -f $passCount, $scenarios.Count)
  Write-Host ("valid_cases={0}/{1}" -f (@($caseRows | Where-Object { $_.score_status -eq 'valid' }).Count), $caseRows.Count)

  Write-Host ''
  Write-Host 'category_summary:'
  $caseRows | Group-Object category | ForEach-Object {
    $GroupRows = @($_.Group)
    $Top1Hits = @($GroupRows | Where-Object { $_.top1_hit }).Count
    $Top3Hits = @($GroupRows | Where-Object { $_.top3_hit }).Count
    $MeanMrr = if ($GroupRows.Count -gt 0) {
      [Math]::Round((($GroupRows | Measure-Object -Property mrr -Average).Average), 4)
    } else { 0.0 }
    [PSCustomObject]@{
      category = $_.Name
      valid_cases = ('{0}/{1}' -f (@($GroupRows | Where-Object { $_.score_status -eq 'valid' }).Count), $GroupRows.Count)
      top1 = ('{0}/{1}' -f $Top1Hits, $GroupRows.Count)
      top3 = ('{0}/{1}' -f $Top3Hits, $GroupRows.Count)
      mrr = $MeanMrr
    }
  } | Format-Table -AutoSize

  if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'failure_details:'
    $failures | Format-Table -AutoSize
    if (-not $IgnoreFailures) {
      exit 1
    }
  }
}
finally {
  if ($predictive -ne [IntPtr]::Zero) {
    [AlphaNative]::alpha_predictive_free($predictive)
  }
}
