param(
  [string]$InstallDir = "",
  [string]$RimeUserDir = "$env:APPDATA\\Rime",
  [switch]$SkipGuiGuide,
  [switch]$SkipDeploy
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevated {
  param([string]$ScriptPath)

  if (Test-IsAdmin) {
    return
  }

  $argList = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $ScriptPath)
  )
  if ($InstallDir) { $argList += @('-InstallDir', ('"{0}"' -f $InstallDir)) }
  if ($RimeUserDir) { $argList += @('-RimeUserDir', ('"{0}"' -f $RimeUserDir)) }
  if ($SkipGuiGuide) { $argList += '-SkipGuiGuide' }
  if ($SkipDeploy) { $argList += '-SkipDeploy' }

  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
  exit
}

function Select-InstallDirectory {
  param([string]$DefaultPath)

  Add-Type -AssemblyName System.Windows.Forms
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = '选择 Wisdom-Weasel 安装目录（默认覆盖 C:\Program Files\Rime\weasel-0.17.4）'
  if ($DefaultPath -and (Test-Path $DefaultPath)) {
    $dialog.SelectedPath = $DefaultPath
  }
  $result = $dialog.ShowDialog()
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    throw '已取消安装。'
  }
  return $dialog.SelectedPath
}

function Copy-DirectoryContents {
  param(
    [string]$Source,
    [string]$Destination,
    [string[]]$ExcludeExtensions = @()
  )

  if (!(Test-Path $Source)) {
    throw "Source directory not found: $Source"
  }

  Get-ChildItem -LiteralPath $Source -Recurse -Force | ForEach-Object {
    $relative = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative
    if ($_.PSIsContainer) {
      New-Item -ItemType Directory -Path $target -Force | Out-Null
      return
    }

    if ($ExcludeExtensions -contains $_.Extension.ToLowerInvariant()) {
      return
    }

    $parent = Split-Path -Parent $target
    if ($parent) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

function Update-SchemaList {
  param([string]$Path)

  $schemas = [System.Collections.Generic.List[string]]::new()
  if (Test-Path $Path) {
    $raw = Get-Content -Raw -Path $Path
    foreach ($m in [regex]::Matches($raw, 'schema:\s*([A-Za-z0-9_]+)')) {
      $schema = $m.Groups[1].Value
      if (-not $schemas.Contains($schema)) {
        [void]$schemas.Add($schema)
      }
    }
  }

  foreach ($schema in @('wanxiang', 'wanxiang_pro')) {
    if (-not $schemas.Contains($schema)) {
      [void]$schemas.Add($schema)
    }
  }

  $lines = @('patch:', '  schema_list:')
  foreach ($schema in $schemas) {
    $lines += "    - {schema: $schema}"
  }
  Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding utf8
}

function Write-WanxiangPatches {
  param(
    [string]$RimeDir,
    [string]$AlphaDllPath,
    [string]$AlphaConfigPath
  )

  $patch = @"
patch:
  alpha_rerank/enabled: true
  alpha_rerank/config_path: "$AlphaConfigPath"
  alpha_rerank/dll_path: "$AlphaDllPath"
  alpha_rerank/max_candidates: 6
  alpha_rerank/context_max_chars: 64
  alpha_rerank/recent_tail_chars: 16
  alpha_rerank/order_prior_weight: 0.02
"@
  Set-Content -Path (Join-Path $RimeDir 'wanxiang.custom.yaml') -Value $patch -Encoding utf8
  Set-Content -Path (Join-Path $RimeDir 'wanxiang_pro.custom.yaml') -Value $patch -Encoding utf8

  Update-SchemaList -Path (Join-Path $RimeDir 'default.custom.yaml')
}

function Open-GuiGuide {
  param(
    [string]$TargetDir,
    [string]$RimeDir
  )

  Add-Type -AssemblyName System.Windows.Forms
  $message = @"
Wisdom-Weasel 已安装完成。

建议下一步：
1. 在 GUI 中打开“小狼毫输入法设定”
2. 勾选 wanxiang / wanxiang_pro
3. 如需修改 LLM，请编辑：
   - $RimeDir\weasel.custom.yaml
   - $RimeDir\wanxiang.custom.yaml
   - $RimeDir\wanxiang_pro.custom.yaml

程序目录：
$TargetDir

Rime 用户目录：
$RimeDir
"@
  [System.Windows.Forms.MessageBox]::Show($message, 'Wisdom-Weasel 安装完成') | Out-Null
}

$scriptPath = $MyInvocation.MyCommand.Path
Ensure-Elevated -ScriptPath $scriptPath

$bundleRoot = Split-Path -Parent $PSScriptRoot
$defaultInstallDir = 'C:\Program Files\Rime\weasel-0.17.4'
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Select-InstallDirectory -DefaultPath $defaultInstallDir
}

$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)
$RimeUserDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RimeUserDir)

$appSource = Join-Path $bundleRoot 'output'
$modelOnnxDir = Join-Path $bundleRoot 'alpha_backend\model\qwen3-0.6b-onnx-int8'
$modelLmdbDir = Join-Path $bundleRoot 'alpha_backend\model\qwen3-0.6b-embeddings_lmdb'
$alphaRuntimeDir = Join-Path $bundleRoot 'alpha_backend\target\release'
$alphaConfigTemplate = Join-Path $bundleRoot 'alpha_backend\config.example.toml'

if (!(Test-Path $appSource)) { throw "Missing output directory: $appSource" }
if (!(Test-Path $modelOnnxDir)) { throw "Missing ONNX model directory: $modelOnnxDir" }
if (!(Test-Path $modelLmdbDir)) { throw "Missing LMDB model directory: $modelLmdbDir" }
if (!(Test-Path $alphaRuntimeDir)) { throw "Missing alpha runtime directory: $alphaRuntimeDir" }
if (!(Test-Path $alphaConfigTemplate)) { throw "Missing config template: $alphaConfigTemplate" }

Write-Host "==> 复制程序文件到 $InstallDir"
Copy-DirectoryContents -Source $appSource -Destination $InstallDir -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj', '.iobj', '.ipdb')

$targetModelRoot = Join-Path $InstallDir 'alpha_backend\model'
Write-Host "==> 复制 Alpha 模型文件"
Copy-DirectoryContents -Source $modelOnnxDir -Destination (Join-Path $targetModelRoot 'qwen3-0.6b-onnx-int8')
Copy-DirectoryContents -Source $modelLmdbDir -Destination (Join-Path $targetModelRoot 'qwen3-0.6b-embeddings_lmdb')

$targetRuntimeRoot = Join-Path $InstallDir 'alpha_backend\target\release'
Write-Host "==> 复制 Alpha 运行时"
Copy-DirectoryContents -Source $alphaRuntimeDir -Destination $targetRuntimeRoot -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj')

Write-Host "==> 安装万象到 $RimeUserDir"
& (Join-Path $PSScriptRoot 'Install-RimeWanxiang.ps1') -RimeUserDir $RimeUserDir -SourceRoot $bundleRoot

$rimeAlphaDir = Join-Path $RimeUserDir 'lua\wanxiang'
$rimeAlphaConfigPath = Join-Path $rimeAlphaDir 'alpha_rerank_config.toml'
$modelOnnxPath = (Join-Path $targetModelRoot 'qwen3-0.6b-onnx-int8\model.onnx').Replace('\', '/')
$tokenizerPath = (Join-Path $targetModelRoot 'qwen3-0.6b-onnx-int8\tokenizer.json').Replace('\', '/')
$lmdbPath = (Join-Path $targetModelRoot 'qwen3-0.6b-embeddings_lmdb').Replace('\', '/')

$alphaConfig = @"
[model]
path = "$modelOnnxPath"
tokenizer = "$tokenizerPath"
max_input_length = 32
inference_hardware = "cpu"
optimization_level = 3

[database]
path = "$lmdbPath"
map_size_mb = 1024
read_only = true
"@
Set-Content -Path $rimeAlphaConfigPath -Value $alphaConfig -Encoding utf8

$alphaDll = (Join-Path $rimeAlphaDir 'alpha_input.dll').Replace('\', '/')
$alphaCfg = $rimeAlphaConfigPath.Replace('\', '/')
Write-WanxiangPatches -RimeDir $RimeUserDir -AlphaDllPath $alphaDll -AlphaConfigPath $alphaCfg

$weaselCustomPath = Join-Path $RimeUserDir 'weasel.custom.yaml'
if (!(Test-Path $weaselCustomPath)) {
  Set-Content -Path $weaselCustomPath -Value "patch:`r`n" -Encoding utf8
}

if (-not $SkipDeploy) {
  $deployer = Join-Path $InstallDir 'WeaselDeployer.exe'
  if (Test-Path $deployer) {
    Write-Host "==> 重新部署 Rime"
    Start-Process -FilePath $deployer -ArgumentList '/deploy' -Wait
    Start-Process -FilePath $deployer
  }
}

Start-Process explorer.exe $RimeUserDir
if (-not $SkipGuiGuide) {
  Open-GuiGuide -TargetDir $InstallDir -RimeDir $RimeUserDir
}

Write-Host ''
Write-Host '安装完成。'
Write-Host "程序目录: $InstallDir"
Write-Host "Rime 用户目录: $RimeUserDir"
Write-Host "Alpha 配置: $rimeAlphaConfigPath"
