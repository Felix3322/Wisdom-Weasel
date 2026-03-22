[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot '..\alpha_backend\config.toml'),
  [string]$DllPath = (Join-Path $PSScriptRoot '..\alpha_backend\target\release\alpha_input.dll'),
  [int]$WarmupIterations = 6,
  [int]$Iterations = 30
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

    [DllImport("$DllImportPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern int alpha_predictive_update_user_preference(IntPtr predictive, IntPtr committedText);

    [DllImport("$DllImportPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern int alpha_predictive_apply_user_feedback(
        IntPtr predictive,
        IntPtr committedText,
        IntPtr[] negativeCandidates,
        int numNegativeCandidates);
}
"@

Add-Type -TypeDefinition $source -Language CSharp
[AlphaNative]::SetDllDirectory($DllDir) | Out-Null
[Environment]::CurrentDirectory = $DllDir

$initTimer = [System.Diagnostics.Stopwatch]::StartNew()
$predictive = [AlphaNative]::alpha_predictive_new($ConfigPath)
$initTimer.Stop()
if ($predictive -eq [IntPtr]::Zero) {
  throw "alpha_predictive_new failed"
}

Write-Host ("init_ms={0:N3}" -f $initTimer.Elapsed.TotalMilliseconds)

function Invoke-AlphaCall {
  param(
    [IntPtr]$Handle,
    [string]$InputText,
    [string[]]$Candidates
  )

  $pointers = New-Object System.IntPtr[] ($Candidates.Count)
  $inputPtr = [IntPtr]::Zero
  try {
    $inputPtr = New-Utf8Pointer $InputText
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
      $pointers[$i] = New-Utf8Pointer $Candidates[$i]
    }

    $resultPtr = [IntPtr]::Zero
    $count = [AlphaNative]::alpha_predictive_compute_similarities_ordered(
      $Handle,
      $inputPtr,
      $pointers,
      $Candidates.Count,
      [ref]$resultPtr
    )

    if ($count -lt 0) {
      throw "alpha_predictive_compute_similarities_ordered failed"
    }

    if ($count -gt 0 -and $resultPtr -ne [IntPtr]::Zero) {
      [AlphaNative]::alpha_predictive_free_similarities_result($resultPtr, $count)
    }
  }
  finally {
    if ($inputPtr -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::FreeHGlobal($inputPtr)
    }
    foreach ($ptr in $pointers) {
      if ($ptr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
      }
    }
  }
}

function New-Utf8Pointer {
  param([string]$Text)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text + [char]0)
  $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
  [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $bytes.Length)
  return $ptr
}

function Get-Stats {
  param([double[]]$Values)
  $sorted = $Values | Sort-Object
  $avg = ($Values | Measure-Object -Average).Average
  $p50 = $sorted[[Math]::Floor(($sorted.Count - 1) * 0.50)]
  $p95 = $sorted[[Math]::Floor(($sorted.Count - 1) * 0.95)]
  [PSCustomObject]@{
    avg_ms = [Math]::Round($avg, 3)
    p50_ms = [Math]::Round($p50, 3)
    p95_ms = [Math]::Round($p95, 3)
    min_ms = [Math]::Round($sorted[0], 3)
    max_ms = [Math]::Round($sorted[-1], 3)
  }
}

function Invoke-AlphaFeedback {
  param(
    [IntPtr]$Handle,
    [string]$CommittedText,
    [string[]]$NegativeCandidates
  )

  $committedPtr = [IntPtr]::Zero
  $negativePtrs = New-Object System.IntPtr[] (($NegativeCandidates | Measure-Object).Count)
  try {
    $committedPtr = New-Utf8Pointer $CommittedText
    for ($i = 0; $i -lt $negativePtrs.Count; $i++) {
      $negativePtrs[$i] = New-Utf8Pointer $NegativeCandidates[$i]
    }

    $status = [AlphaNative]::alpha_predictive_apply_user_feedback(
      $Handle,
      $committedPtr,
      $negativePtrs,
      $negativePtrs.Count
    )

    if ($status -ne 0) {
      throw "alpha_predictive_apply_user_feedback failed"
    }
  }
  finally {
    if ($committedPtr -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::FreeHGlobal($committedPtr)
    }
    foreach ($ptr in $negativePtrs) {
      if ($ptr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
      }
    }
  }
}

$scenarios = @(
  [PSCustomObject]@{
    Name = 'repeat_6'
    Input = '用户输入记录：今天我们准备把发布会流程和杭州出差安排一起确认一下'
    Candidates = @('发布会流程', '杭州出差', '安排确认', '讨论细节', '会议纪要', '时间调整')
  },
  [PSCustomObject]@{
    Name = 'repeat_8'
    Input = '用户输入记录：这周继续整理输入法重排延迟和用户偏好向量的设计方案'
    Candidates = @('输入法', '重排延迟', '用户偏好', '向量设计', '缓存优化', '模型推理', '候选排序', '本地 DLL')
  },
  [PSCustomObject]@{
    Name = 'session_pref_6'
    Input = '用户输入记录：最近几天一直在写 Rust 缓存和 Lua 侧的重排逻辑'
    Candidates = @('Rust 缓存', 'Lua 重排', '性能优化', '用户偏好', '候选顺序', '本地推理')
  }
)

try {
  Invoke-AlphaFeedback -Handle $predictive -CommittedText 'Rust 缓存' -NegativeCandidates @('会议纪要', '时间调整')
  foreach ($text in @('Rust 缓存', 'Lua 重排', '性能优化')) {
    $ptr = New-Utf8Pointer $text
    try {
      [AlphaNative]::alpha_predictive_update_user_preference($predictive, $ptr) | Out-Null
    }
    finally {
      [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
    }
  }

  $results = @()
  foreach ($scenario in $scenarios) {
    for ($i = 0; $i -lt $WarmupIterations; $i++) {
      Invoke-AlphaCall -Handle $predictive -InputText $scenario.Input -Candidates $scenario.Candidates
    }

    $samples = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Iterations; $i++) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      Invoke-AlphaCall -Handle $predictive -InputText $scenario.Input -Candidates $scenario.Candidates
      $sw.Stop()
      [void]$samples.Add($sw.Elapsed.TotalMilliseconds)
    }

    $stats = Get-Stats -Values $samples.ToArray()
    $results += [PSCustomObject]@{
      scenario = $scenario.Name
      avg_ms = $stats.avg_ms
      p50_ms = $stats.p50_ms
      p95_ms = $stats.p95_ms
      min_ms = $stats.min_ms
      max_ms = $stats.max_ms
    }
  }

  $results | Format-Table -AutoSize
}
finally {
  if ($predictive -ne [IntPtr]::Zero) {
    [AlphaNative]::alpha_predictive_free($predictive)
  }
}
