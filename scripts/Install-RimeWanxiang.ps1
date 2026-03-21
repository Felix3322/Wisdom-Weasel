param(
  [string]$RimeUserDir = "$env:APPDATA\\Rime",
  [string]$SourceRoot = ""
)

$ErrorActionPreference = 'Stop'

$root = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  Split-Path -Parent $PSScriptRoot
} else {
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceRoot)
}
$source = Join-Path $root 'third_party\rime_wanxiang'

if (!(Test-Path $source)) {
  throw "Source directory not found: $source"
}

New-Item -ItemType Directory -Force -Path $RimeUserDir | Out-Null

$copyDirs = @('custom', 'dicts', 'lua')
foreach ($dir in $copyDirs) {
  $srcDir = Join-Path $source $dir
  if (Test-Path $srcDir) {
    Copy-Item $srcDir -Destination $RimeUserDir -Recurse -Force
  }
}

$copyFiles = @(
  'README.md',
  'LICENSE',
  'version.txt',
  'custom_phrase.txt',
  'default.yaml',
  'wanxiang_algebra.yaml',
  'wanxiang.dict.yaml',
  'wanxiang.schema.yaml',
  'wanxiang_english.dict.yaml',
  'wanxiang_english.schema.yaml',
  'wanxiang_mixedcode.dict.yaml',
  'wanxiang_mixedcode.schema.yaml',
  'wanxiang_reverse.dict.yaml',
  'wanxiang_reverse.schema.yaml',
  'wanxiang_symbols.yaml',
  'wanxiang_t9.schema.yaml',
  'weasel.yaml'
)

foreach ($file in $copyFiles) {
  $srcFile = Join-Path $source $file
  if (Test-Path $srcFile) {
    Copy-Item $srcFile -Destination $RimeUserDir -Force
  }
}

$alphaRuntimeDir = Join-Path $RimeUserDir 'lua\wanxiang'
New-Item -ItemType Directory -Force -Path $alphaRuntimeDir | Out-Null

$alphaCoreSource = Join-Path $root 'output\lua\wanxiang\alpha_rerank_core.dll'
if (!(Test-Path $alphaCoreSource)) {
  $alphaCoreSource = Join-Path $root 'output\Win32\lua\wanxiang\alpha_rerank_core.dll'
}

$alphaCorePdbSource = Join-Path $root 'output\lua\wanxiang\alpha_rerank_core.pdb'
if (!(Test-Path $alphaCorePdbSource)) {
  $alphaCorePdbSource = Join-Path $root 'output\Win32\lua\wanxiang\alpha_rerank_core.pdb'
}

$alphaRuntimeSourceDir = Join-Path $root 'third_party\alpha-input\target\release'
if (!(Test-Path $alphaRuntimeSourceDir)) {
  $alphaRuntimeSourceDir = Join-Path $root 'alpha_backend\target\release'
}

$optionalAlphaFiles = @(
  @{ Source = $alphaCoreSource; Destination = (Join-Path $alphaRuntimeDir 'alpha_rerank_core.dll') },
  @{ Source = $alphaCorePdbSource; Destination = (Join-Path $alphaRuntimeDir 'alpha_rerank_core.pdb') },
  @{ Source = (Join-Path $alphaRuntimeSourceDir 'alpha_input.dll'); Destination = (Join-Path $alphaRuntimeDir 'alpha_input.dll') },
  @{ Source = (Join-Path $alphaRuntimeSourceDir 'onnxruntime.dll'); Destination = (Join-Path $alphaRuntimeDir 'onnxruntime.dll') },
  @{ Source = (Join-Path $alphaRuntimeSourceDir 'onnxruntime_providers_shared.dll'); Destination = (Join-Path $alphaRuntimeDir 'onnxruntime_providers_shared.dll') },
  @{ Source = (Join-Path $root 'alpha_backend\config.example.toml'); Destination = (Join-Path $alphaRuntimeDir 'alpha_rerank_config.example.toml') }
)

$copiedAlphaRuntime = $false
foreach ($entry in $optionalAlphaFiles) {
  if (Test-Path $entry.Source) {
    Copy-Item $entry.Source -Destination $entry.Destination -Force
    $copiedAlphaRuntime = $true
  }
}

Write-Host "rime_wanxiang 已复制到: $RimeUserDir"
if ($copiedAlphaRuntime) {
  Write-Host "已同步 Alpha Rerank 运行时文件到: $alphaRuntimeDir"
  Write-Host "若要启用 Rime 内 Alpha 重排，请在方案 patch 中填写 alpha_rerank/config_path 与 alpha_rerank/dll_path。"
}
Write-Host "注意: 语法模型二进制文件不在仓库内，请按上游说明额外下载并放到 Rime 用户目录根目录。"
