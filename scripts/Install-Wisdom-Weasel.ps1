param(
  [string]$InstallDir = "",
  [string]$RimeUserDir = "$env:APPDATA\Rime",
  [string]$RepoOwner = "Felix3322",
  [string]$RepoName = "Wisdom-Weasel",
  [string]$ReleaseTag = "",
  [string]$SourceRef = "",
  [ValidateSet('prompt', 'auto', 'local', 'skip')]
  [string]$ModelSetup = 'prompt',
  [string]$AlphaModelId = 'Qwen/Qwen3-0.6B',
  [string]$LocalModelDir = '',
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
  if ($RepoOwner) { $argList += @('-RepoOwner', ('"{0}"' -f $RepoOwner)) }
  if ($RepoName) { $argList += @('-RepoName', ('"{0}"' -f $RepoName)) }
  if ($ReleaseTag) { $argList += @('-ReleaseTag', ('"{0}"' -f $ReleaseTag)) }
  if ($SourceRef) { $argList += @('-SourceRef', ('"{0}"' -f $SourceRef)) }
  if ($ModelSetup) { $argList += @('-ModelSetup', $ModelSetup) }
  if ($AlphaModelId) { $argList += @('-AlphaModelId', ('"{0}"' -f $AlphaModelId)) }
  if ($LocalModelDir) { $argList += @('-LocalModelDir', ('"{0}"' -f $LocalModelDir)) }
  if ($SkipGuiGuide) { $argList += '-SkipGuiGuide' }
  if ($SkipDeploy) { $argList += '-SkipDeploy' }

  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
  exit
}

function Add-WinForms {
  Add-Type -AssemblyName System.Windows.Forms
}

function New-EmptyDir {
  param([string]$Path)

  if (Test-Path $Path) {
    Remove-Item $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Select-InstallDirectory {
  param([string]$DefaultPath)

  Add-WinForms
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

function Select-LocalModelDirectory {
  param([string]$DefaultPath)

  Add-WinForms
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = '选择本地 Hugging Face 模型目录（应包含 config.json / tokenizer / safetensors 等文件）'
  if ($DefaultPath -and (Test-Path $DefaultPath)) {
    $dialog.SelectedPath = $DefaultPath
  }
  $result = $dialog.ShowDialog()
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    throw '已取消选择本地模型目录。'
  }
  return $dialog.SelectedPath
}

function Select-ModelSetupMode {
  param([bool]$HasExistingModel)

  Add-WinForms

  $cancelText = if ($HasExistingModel) {
    '取消：保留当前已安装的 Alpha 模型，不重新转换'
  } else {
    '取消：暂时跳过 Alpha 模型安装，稍后可重新运行安装器补装'
  }

  $message = @"
Alpha 模型不再随 Release 打包，避免上传/下载超大资产。

是(Y)：从 Hugging Face 下载推荐模型，并在本机转换
否(N)：选择本地已下载的 Hugging Face 模型目录并转换
$cancelText
"@

  $result = [System.Windows.Forms.MessageBox]::Show(
    $message,
    'Alpha 模型安装方式',
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )

  switch ($result) {
    ([System.Windows.Forms.DialogResult]::Yes) { return 'auto' }
    ([System.Windows.Forms.DialogResult]::No) { return 'local' }
    default { return 'skip' }
  }
}

function Get-GitHubApiHeaders {
  $headers = @{ 'User-Agent' = 'Wisdom-Weasel-Installer' }
  if ($env:GITHUB_TOKEN) {
    $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
  } elseif ($env:GH_TOKEN) {
    $headers['Authorization'] = "Bearer $($env:GH_TOKEN)"
  }
  return $headers
}

function Invoke-GitHubJson {
  param([string]$Url)
  return Invoke-RestMethod -Uri $Url -Headers (Get-GitHubApiHeaders)
}

function Download-File {
  param(
    [string]$Url,
    [string]$Destination
  )

  $parent = Split-Path -Parent $Destination
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Write-Host "==> 下载: $Url"
  Invoke-WebRequest -Uri $Url -Headers (Get-GitHubApiHeaders) -OutFile $Destination
}

function Expand-ZipArchive {
  param(
    [string]$ZipPath,
    [string]$Destination
  )

  if (Test-Path $Destination) {
    Remove-Item $Destination -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Get-LatestRelease {
  param(
    [string]$Owner,
    [string]$Repo
  )

  $releases = Invoke-GitHubJson "https://api.github.com/repos/$Owner/$Repo/releases?per_page=20"
  $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
  if (-not $release) {
    throw "未找到已发布 release：$Owner/$Repo"
  }
  return $release
}

function Get-ReleaseByTag {
  param(
    [string]$Owner,
    [string]$Repo,
    [string]$Tag
  )

  return Invoke-GitHubJson "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag"
}

function Get-ReleaseAssetUrl {
  param(
    $Release,
    [string]$Prefix
  )

  $asset = $Release.assets | Where-Object { $_.name -like "$Prefix*" } | Select-Object -First 1
  if (-not $asset) {
    throw "未找到 release 资产：$Prefix*"
  }
  return $asset.browser_download_url
}

function Find-SourceSnapshotRoot {
  param([string]$ExpandedDir)

  $dir = Get-ChildItem -LiteralPath $ExpandedDir -Directory | Select-Object -First 1
  if (-not $dir) {
    throw "无法识别源码快照目录：$ExpandedDir"
  }
  return $dir.FullName
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

function Replace-Directory {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (Test-Path $Destination) {
    Remove-Item $Destination -Recurse -Force
  }
  Copy-DirectoryContents -Source $Source -Destination $Destination
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

function Get-AlphaModelLayout {
  param([string]$ModelRoot)

  return [pscustomobject]@{
    HfDir = Join-Path $ModelRoot 'qwen3-0.6b-hf'
    OnnxDir = Join-Path $ModelRoot 'qwen3-0.6b-onnx-int8'
    OnnxFile = Join-Path $ModelRoot 'qwen3-0.6b-onnx-int8\model.onnx'
    TokenizerFile = Join-Path $ModelRoot 'qwen3-0.6b-onnx-int8\tokenizer.json'
    LmdbDir = Join-Path $ModelRoot 'qwen3-0.6b-embeddings_lmdb'
  }
}

function Test-AlphaModelInstalled {
  param([string]$ModelRoot)

  $layout = Get-AlphaModelLayout -ModelRoot $ModelRoot
  if (!(Test-Path $layout.OnnxFile)) { return $false }
  if (!(Test-Path $layout.TokenizerFile)) { return $false }
  if (!(Test-Path $layout.LmdbDir)) { return $false }

  $lmdbFiles = Get-ChildItem -LiteralPath $layout.LmdbDir -File -ErrorAction SilentlyContinue
  return $null -ne $lmdbFiles -and $lmdbFiles.Count -gt 0
}

function Copy-FirstExistingFile {
  param(
    [string[]]$Candidates,
    [string]$Destination
  )

  foreach ($candidate in $Candidates) {
    if (Test-Path $candidate) {
      $parent = Split-Path -Parent $Destination
      if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
      }
      Copy-Item -LiteralPath $candidate -Destination $Destination -Force
      return $true
    }
  }
  return $false
}

function Sync-AlphaRuntimeToRime {
  param(
    [string]$RuntimeRoot,
    [string]$InstallRoot,
    [string]$RimeDir,
    [string]$SourceRoot
  )

  $alphaRuntimeDir = Join-Path $RimeDir 'lua\wanxiang'
  New-Item -ItemType Directory -Force -Path $alphaRuntimeDir | Out-Null

  $entries = @(
    @{
      Destination = Join-Path $alphaRuntimeDir 'alpha_rerank_core.dll'
      Candidates = @(
        (Join-Path $InstallRoot 'lua\wanxiang\alpha_rerank_core.dll'),
        (Join-Path $RuntimeRoot 'output\lua\wanxiang\alpha_rerank_core.dll'),
        (Join-Path $SourceRoot 'output\lua\wanxiang\alpha_rerank_core.dll'),
        (Join-Path $SourceRoot 'output\Win32\lua\wanxiang\alpha_rerank_core.dll')
      )
    },
    @{
      Destination = Join-Path $alphaRuntimeDir 'alpha_rerank_core.pdb'
      Candidates = @(
        (Join-Path $InstallRoot 'lua\wanxiang\alpha_rerank_core.pdb'),
        (Join-Path $RuntimeRoot 'output\lua\wanxiang\alpha_rerank_core.pdb'),
        (Join-Path $SourceRoot 'output\lua\wanxiang\alpha_rerank_core.pdb'),
        (Join-Path $SourceRoot 'output\Win32\lua\wanxiang\alpha_rerank_core.pdb')
      )
    },
    @{
      Destination = Join-Path $alphaRuntimeDir 'alpha_input.dll'
      Candidates = @(
        (Join-Path $InstallRoot 'alpha_backend\target\release\alpha_input.dll'),
        (Join-Path $RuntimeRoot 'alpha_backend\target\release\alpha_input.dll'),
        (Join-Path $SourceRoot 'alpha_backend\target\release\alpha_input.dll'),
        (Join-Path $SourceRoot 'third_party\alpha-input\target\release\alpha_input.dll')
      )
    },
    @{
      Destination = Join-Path $alphaRuntimeDir 'onnxruntime.dll'
      Candidates = @(
        (Join-Path $InstallRoot 'alpha_backend\target\release\onnxruntime.dll'),
        (Join-Path $RuntimeRoot 'alpha_backend\target\release\onnxruntime.dll'),
        (Join-Path $SourceRoot 'alpha_backend\target\release\onnxruntime.dll'),
        (Join-Path $SourceRoot 'third_party\alpha-input\target\release\onnxruntime.dll')
      )
    },
    @{
      Destination = Join-Path $alphaRuntimeDir 'onnxruntime_providers_shared.dll'
      Candidates = @(
        (Join-Path $InstallRoot 'alpha_backend\target\release\onnxruntime_providers_shared.dll'),
        (Join-Path $RuntimeRoot 'alpha_backend\target\release\onnxruntime_providers_shared.dll'),
        (Join-Path $SourceRoot 'alpha_backend\target\release\onnxruntime_providers_shared.dll'),
        (Join-Path $SourceRoot 'third_party\alpha-input\target\release\onnxruntime_providers_shared.dll')
      )
    },
    @{
      Destination = Join-Path $alphaRuntimeDir 'alpha_rerank_config.example.toml'
      Candidates = @(
        (Join-Path $SourceRoot 'alpha_backend\config.example.toml')
      )
    }
  )

  foreach ($entry in $entries) {
    [void](Copy-FirstExistingFile -Candidates $entry.Candidates -Destination $entry.Destination)
  }
}

function Write-WanxiangPatches {
  param(
    [string]$RimeDir,
    [string]$AlphaDllPath,
    [string]$AlphaConfigPath,
    [bool]$Enabled
  )

  $enabledValue = if ($Enabled) { 'true' } else { 'false' }
  $patch = @"
patch:
  alpha_rerank/enabled: $enabledValue
  alpha_rerank/config_path: "$AlphaConfigPath"
  alpha_rerank/dll_path: "$AlphaDllPath"
  alpha_rerank/max_candidates: 6
  alpha_rerank/context_max_chars: 64
  alpha_rerank/recent_tail_chars: 16
  alpha_rerank/order_prior_weight: 0.02
  alpha_rerank/log_enabled: false
"@

  Set-Content -Path (Join-Path $RimeDir 'wanxiang.custom.yaml') -Value $patch -Encoding utf8
  Set-Content -Path (Join-Path $RimeDir 'wanxiang_pro.custom.yaml') -Value $patch -Encoding utf8
  Update-SchemaList -Path (Join-Path $RimeDir 'default.custom.yaml')
}

function Write-AlphaConfig {
  param(
    [string]$ConfigPath,
    [string]$ModelRoot
  )

  $layout = Get-AlphaModelLayout -ModelRoot $ModelRoot
  $modelOnnxPath = $layout.OnnxFile.Replace('\', '/')
  $tokenizerPath = $layout.TokenizerFile.Replace('\', '/')
  $lmdbPath = $layout.LmdbDir.Replace('\', '/')

  $alphaConfig = @"
[model]
path = "$modelOnnxPath"
tokenizer = "$tokenizerPath"
max_input_length = 64
inference_hardware = "cpu"
optimization_level = 3

[database]
path = "$lmdbPath"
map_size_mb = 1024
read_only = true
"@

  $parent = Split-Path -Parent $ConfigPath
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Set-Content -Path $ConfigPath -Value $alphaConfig -Encoding utf8
}

function Get-PythonLauncher {
  $candidates = @(
    @{ Exe = 'py.exe'; Args = @('-3') },
    @{ Exe = 'py'; Args = @('-3') },
    @{ Exe = 'python.exe'; Args = @() },
    @{ Exe = 'python'; Args = @() }
  )

  foreach ($candidate in $candidates) {
    try {
      $command = Get-Command $candidate.Exe -ErrorAction Stop
      return [pscustomobject]@{
        Exe = $command.Source
        Args = $candidate.Args
      }
    } catch {
    }
  }

  throw '未找到 Python 3。请先安装 Python 3，并确保 py / python 可用。'
}

function Invoke-NativeCommand {
  param(
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = ''
  )

  $displayParts = @($FilePath) + $Arguments
  $displayCommand = ($displayParts | ForEach-Object {
      if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }) -join ' '

  Write-Host "==> 执行: $displayCommand"

  if ($WorkingDirectory) {
    Push-Location $WorkingDirectory
  }

  try {
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
  } finally {
    if ($WorkingDirectory) {
      Pop-Location
    }
  }

  if ($exitCode -ne 0) {
    throw "命令执行失败（exit=$exitCode）：$displayCommand"
  }
}

function Invoke-InlinePython {
  param(
    [string]$PythonPath,
    [string]$Code,
    [string[]]$Arguments = @()
  )

  $tempScript = Join-Path $env:TEMP ("wisdom-weasel-inline-" + [guid]::NewGuid().ToString('N') + '.py')
  Set-Content -Path $tempScript -Value $Code -Encoding utf8
  try {
    Invoke-NativeCommand -FilePath $PythonPath -Arguments (@($tempScript) + $Arguments)
  } finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-ModelConversionPython {
  param([string]$VenvDir)

  $venvPython = Join-Path $VenvDir 'Scripts\python.exe'
  if (Test-Path $venvPython) {
    return $venvPython
  }

  $launcher = Get-PythonLauncher
  $venvParent = Split-Path -Parent $VenvDir
  if ($venvParent) {
    New-Item -ItemType Directory -Force -Path $venvParent | Out-Null
  }

  Invoke-NativeCommand -FilePath $launcher.Exe -Arguments ($launcher.Args + @('-m', 'venv', $VenvDir))

  if (!(Test-Path $venvPython)) {
    throw "创建 Python 虚拟环境失败：$VenvDir"
  }

  return $venvPython
}

function Ensure-ModelConversionDependencies {
  param([string]$PythonPath)

  Invoke-NativeCommand -FilePath $PythonPath -Arguments @(
    '-m', 'pip', '--disable-pip-version-check',
    'install', '--upgrade',
    'pip', 'setuptools', 'wheel'
  )

  Invoke-NativeCommand -FilePath $PythonPath -Arguments @(
    '-m', 'pip', '--disable-pip-version-check',
    'install',
    'torch',
    'transformers',
    'huggingface_hub',
    'accelerate',
    'onnx',
    'onnxruntime',
    'numpy',
    'lmdb',
    'tqdm'
  )
}

function Download-HuggingFaceModel {
  param(
    [string]$PythonPath,
    [string]$ModelId,
    [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null

  $code = @"
import sys
from huggingface_hub import snapshot_download

repo_id = sys.argv[1]
destination = sys.argv[2]

snapshot_download(repo_id=repo_id, local_dir=destination)
print(f"Downloaded model to: {destination}")
"@

  Invoke-InlinePython -PythonPath $PythonPath -Code $code -Arguments @($ModelId, $Destination)
}

function Convert-AlphaModel {
  param(
    [string]$PythonPath,
    [string]$SourceRoot,
    [string]$ModelSourceDir,
    [string]$StagingRoot
  )

  $stagingLayout = Get-AlphaModelLayout -ModelRoot $StagingRoot
  New-EmptyDir -Path $StagingRoot

  $exportScript = Join-Path $SourceRoot 'alpha_backend\export_qwen_feature_onnx.py'
  $lmdbScript = Join-Path $SourceRoot 'third_party\alpha-input\script\export_embeddings_lmdb.py'
  if (!(Test-Path $exportScript)) {
    throw "缺少导出脚本：$exportScript"
  }
  if (!(Test-Path $lmdbScript)) {
    throw "缺少导出脚本：$lmdbScript"
  }

  $env:ALPHA_EXPORT_SEQ_LENGTH = '64'
  try {
    Invoke-NativeCommand -FilePath $PythonPath -Arguments @(
      $exportScript,
      '--model_id', $ModelSourceDir,
      '--output', $stagingLayout.OnnxDir,
      '--quantize', 'int8',
      '--opset', '17'
    ) -WorkingDirectory $SourceRoot
  } finally {
    Remove-Item Env:ALPHA_EXPORT_SEQ_LENGTH -ErrorAction SilentlyContinue
  }

  Invoke-NativeCommand -FilePath $PythonPath -Arguments @(
    $lmdbScript,
    '--model_id', $ModelSourceDir,
    '--db_dir', $stagingLayout.LmdbDir,
    '--batch_size', '1000',
    '--test_token', '1000'
  ) -WorkingDirectory $SourceRoot

  if (!(Test-Path $stagingLayout.OnnxFile)) {
    throw "ONNX 导出失败，未生成：$($stagingLayout.OnnxFile)"
  }
  if (!(Test-Path $stagingLayout.TokenizerFile)) {
    throw "Tokenizer 导出失败，未生成：$($stagingLayout.TokenizerFile)"
  }
  if (!(Test-Path $stagingLayout.LmdbDir)) {
    throw "LMDB 导出失败，未生成：$($stagingLayout.LmdbDir)"
  }

  return $stagingLayout
}

function Install-ConvertedAlphaModel {
  param(
    [string]$PythonPath,
    [string]$SourceRoot,
    [string]$ModelSourceDir,
    [string]$TargetModelRoot,
    [string]$WorkRoot
  )

  $stagingRoot = Join-Path $WorkRoot 'converted-model'
  $stagingLayout = Convert-AlphaModel -PythonPath $PythonPath -SourceRoot $SourceRoot -ModelSourceDir $ModelSourceDir -StagingRoot $stagingRoot
  $targetLayout = Get-AlphaModelLayout -ModelRoot $TargetModelRoot

  New-Item -ItemType Directory -Force -Path $TargetModelRoot | Out-Null
  Replace-Directory -Source $stagingLayout.OnnxDir -Destination $targetLayout.OnnxDir
  Replace-Directory -Source $stagingLayout.LmdbDir -Destination $targetLayout.LmdbDir
}

function Open-GuiGuide {
  param(
    [string]$TargetDir,
    [string]$RimeDir,
    [bool]$AlphaEnabled,
    [string]$ModelStatus,
    [string]$ReleaseTagValue
  )

  Add-WinForms

  $alphaStatus = if ($AlphaEnabled) { '已启用' } else { '未启用' }
  $message = @"
Wisdom-Weasel 已安装完成。

Release：
$ReleaseTagValue

Alpha 重排：
$alphaStatus

模型状态：
$ModelStatus

建议下一步：
1. 打开“小狼毫输入法设定”
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

  [System.Windows.Forms.MessageBox]::Show(
    $message,
    'Wisdom-Weasel 安装完成'
  ) | Out-Null
}

$scriptPath = $MyInvocation.MyCommand.Path
Ensure-Elevated -ScriptPath $scriptPath

$defaultInstallDir = 'C:\Program Files\Rime\weasel-0.17.4'
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Select-InstallDirectory -DefaultPath $defaultInstallDir
}

$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)
$RimeUserDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RimeUserDir)
if ($LocalModelDir) {
  $LocalModelDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LocalModelDir)
}

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  $release = Get-LatestRelease -Owner $RepoOwner -Repo $RepoName
} else {
  $release = Get-ReleaseByTag -Owner $RepoOwner -Repo $RepoName -Tag $ReleaseTag
}

if ([string]::IsNullOrWhiteSpace($SourceRef)) {
  $SourceRef = $release.tag_name
}

$tempRoot = Join-Path $env:TEMP ("wisdom-weasel-install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$sourceZip = Join-Path $tempRoot 'source.zip'
$sourceDir = Join-Path $tempRoot 'source'
$runtimeZip = Join-Path $tempRoot 'runtime.zip'
$runtimeDir = Join-Path $tempRoot 'runtime'
$modelToolsVenv = Join-Path $tempRoot 'model-tools-venv'
$modelWorkDir = Join-Path $tempRoot 'model-work'

$runtimeAssetUrl = Get-ReleaseAssetUrl -Release $release -Prefix 'Wisdom-Weasel-runtime-'
$sourceZipUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/zipball/$SourceRef"

Download-File -Url $sourceZipUrl -Destination $sourceZip
Expand-ZipArchive -ZipPath $sourceZip -Destination $sourceDir
$sourceRoot = Find-SourceSnapshotRoot -ExpandedDir $sourceDir

Download-File -Url $runtimeAssetUrl -Destination $runtimeZip
Expand-ZipArchive -ZipPath $runtimeZip -Destination $runtimeDir

$appSource = Join-Path $runtimeDir 'output'
$alphaRuntimeDir = Join-Path $runtimeDir 'alpha_backend\target\release'
if (!(Test-Path $appSource)) { throw "Missing runtime output directory: $appSource" }
if (!(Test-Path $alphaRuntimeDir)) { throw "Missing alpha runtime directory: $alphaRuntimeDir" }

Write-Host "==> 复制程序文件到 $InstallDir"
Copy-DirectoryContents -Source $appSource -Destination $InstallDir -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj', '.iobj', '.ipdb')

$targetRuntimeRoot = Join-Path $InstallDir 'alpha_backend\target\release'
Write-Host "==> 安装 Alpha 运行时"
Copy-DirectoryContents -Source $alphaRuntimeDir -Destination $targetRuntimeRoot -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj')

$targetModelRoot = Join-Path $InstallDir 'alpha_backend\model'
$targetModelLayout = Get-AlphaModelLayout -ModelRoot $targetModelRoot
$hadExistingAlphaModel = Test-AlphaModelInstalled -ModelRoot $targetModelRoot

Write-Host "==> 安装万象到 $RimeUserDir"
& (Join-Path $sourceRoot 'scripts\Install-RimeWanxiang.ps1') -RimeUserDir $RimeUserDir -SourceRoot $sourceRoot
Sync-AlphaRuntimeToRime -RuntimeRoot $runtimeDir -InstallRoot $InstallDir -RimeDir $RimeUserDir -SourceRoot $sourceRoot

$effectiveModelSetup = $ModelSetup
if ($effectiveModelSetup -eq 'prompt') {
  $effectiveModelSetup = Select-ModelSetupMode -HasExistingModel $hadExistingAlphaModel
}

$modelStatus = if ($hadExistingAlphaModel) {
  '检测到已有 Alpha 模型，将优先复用。'
} else {
  '尚未安装 Alpha 模型。'
}

if ($effectiveModelSetup -eq 'local' -and [string]::IsNullOrWhiteSpace($LocalModelDir)) {
  $LocalModelDir = Select-LocalModelDirectory -DefaultPath $targetModelLayout.HfDir
}

if ($effectiveModelSetup -ne 'skip') {
  try {
    $pythonPath = Ensure-ModelConversionPython -VenvDir $modelToolsVenv
    Ensure-ModelConversionDependencies -PythonPath $pythonPath

    $modelSourceDir = ''
    if ($effectiveModelSetup -eq 'auto') {
      Write-Host "==> 从 Hugging Face 下载推荐 Alpha 模型：$AlphaModelId"
      Download-HuggingFaceModel -PythonPath $pythonPath -ModelId $AlphaModelId -Destination $targetModelLayout.HfDir
      $modelSourceDir = $targetModelLayout.HfDir
      $modelStatus = "已从 Hugging Face 下载并开始转换：$AlphaModelId"
    } elseif ($effectiveModelSetup -eq 'local') {
      if (!(Test-Path $LocalModelDir)) {
        throw "本地模型目录不存在：$LocalModelDir"
      }
      $modelSourceDir = $LocalModelDir
      $modelStatus = "已使用本地模型目录开始转换：$LocalModelDir"
    }

    Install-ConvertedAlphaModel -PythonPath $pythonPath -SourceRoot $sourceRoot -ModelSourceDir $modelSourceDir -TargetModelRoot $targetModelRoot -WorkRoot $modelWorkDir

    if ($effectiveModelSetup -eq 'auto') {
      $modelStatus = "Alpha 模型已从 Hugging Face 下载并本地转换完成：$AlphaModelId"
    } else {
      $modelStatus = "Alpha 模型已由本地目录转换完成：$LocalModelDir"
    }
  } catch {
    Write-Warning ("Alpha 模型安装失败，将继续完成其余安装步骤。错误：{0}" -f $_.Exception.Message)
    if ($hadExistingAlphaModel) {
      $modelStatus = "重新转换失败，已保留原有 Alpha 模型。错误：$($_.Exception.Message)"
    } else {
      $modelStatus = "Alpha 模型未安装成功，当前将保持关闭。错误：$($_.Exception.Message)"
    }
  }
} elseif ($hadExistingAlphaModel) {
  $modelStatus = '已保留现有 Alpha 模型，未重新转换。'
} else {
  $modelStatus = '已跳过 Alpha 模型安装；当前 Alpha 重排将保持关闭。'
}

$alphaEnabled = Test-AlphaModelInstalled -ModelRoot $targetModelRoot

$rimeAlphaDir = Join-Path $RimeUserDir 'lua\wanxiang'
$rimeAlphaConfigPath = Join-Path $rimeAlphaDir 'alpha_rerank_config.toml'
if ($alphaEnabled) {
  Write-AlphaConfig -ConfigPath $rimeAlphaConfigPath -ModelRoot $targetModelRoot
}

$alphaDll = (Join-Path $rimeAlphaDir 'alpha_input.dll').Replace('\', '/')
$alphaCfg = $rimeAlphaConfigPath.Replace('\', '/')
Write-WanxiangPatches -RimeDir $RimeUserDir -AlphaDllPath $alphaDll -AlphaConfigPath $alphaCfg -Enabled $alphaEnabled

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
  Open-GuiGuide -TargetDir $InstallDir -RimeDir $RimeUserDir -AlphaEnabled $alphaEnabled -ModelStatus $modelStatus -ReleaseTagValue $release.tag_name
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '安装完成。'
Write-Host "程序目录: $InstallDir"
Write-Host "Rime 用户目录: $RimeUserDir"
Write-Host "使用 release: $($release.tag_name)"
Write-Host "源码来源: $SourceRef"
Write-Host "Alpha 模型状态: $modelStatus"
if ($alphaEnabled) {
  Write-Host "Alpha 配置: $rimeAlphaConfigPath"
} else {
  Write-Host 'Alpha 重排当前未启用。'
}
