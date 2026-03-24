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
  [string]$OllamaModel = '',
  [ValidateSet('prompt', 'auto')]
  [string]$OllamaModelSelection = 'prompt',
  [string]$OllamaBaseUrl = 'http://127.0.0.1:11434',
  [string]$OllamaInstallScriptUrl = 'https://ollama.com/install.ps1',
  [string]$OllamaInstallerUrl = 'https://ollama.com/download/OllamaSetup.exe',
  [switch]$SkipOllamaSetup,
  [switch]$SkipGuiGuide,
  [switch]$SkipDeploy
)

$ErrorActionPreference = 'Stop'

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

function Get-PowerShellExecutable {
  $candidates = @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')
  foreach ($candidate in $candidates) {
    try {
      $command = Get-Command $candidate -ErrorAction Stop
      return $command.Source
    } catch {
    }
  }

  throw '未找到可用的 PowerShell（pwsh / powershell）。'
}

function Get-OllamaChatCompletionsUrl {
  param([string]$BaseUrl)

  return ($BaseUrl.TrimEnd('/') + '/v1/chat/completions')
}

function New-TimestampString {
  return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

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
  if ($OllamaModel) { $argList += @('-OllamaModel', ('"{0}"' -f $OllamaModel)) }
  if ($OllamaModelSelection) { $argList += @('-OllamaModelSelection', $OllamaModelSelection) }
  if ($OllamaBaseUrl) { $argList += @('-OllamaBaseUrl', ('"{0}"' -f $OllamaBaseUrl)) }
  if ($OllamaInstallScriptUrl) { $argList += @('-OllamaInstallScriptUrl', ('"{0}"' -f $OllamaInstallScriptUrl)) }
  if ($OllamaInstallerUrl) { $argList += @('-OllamaInstallerUrl', ('"{0}"' -f $OllamaInstallerUrl)) }
  if ($SkipOllamaSetup) { $argList += '-SkipOllamaSetup' }
  if ($SkipGuiGuide) { $argList += '-SkipGuiGuide' }
  if ($SkipDeploy) { $argList += '-SkipDeploy' }

  $shellExe = Get-PowerShellExecutable
  Start-Process -FilePath $shellExe -Verb RunAs -ArgumentList $argList
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

function Backup-File {
  param(
    [string]$Path,
    [string]$Label = 'backup'
  )

  if (!(Test-Path $Path)) {
    return $null
  }

  $backupPath = '{0}.{1}.{2}.bak' -f $Path, $Label, (New-TimestampString)
  Copy-Item -LiteralPath $Path -Destination $backupPath -Force
  return $backupPath
}

function Remove-ManagedBlock {
  param([string]$Content)

  if ([string]::IsNullOrEmpty($Content)) {
    return ''
  }

  $pattern = '(?ms)^[ \t]*# >>> Wisdom-Weasel managed Ollama config begin >>>\r?\n.*?^[ \t]*# <<< Wisdom-Weasel managed Ollama config end <<<\r?\n?'
  return ([regex]::Replace($Content, $pattern, '')).TrimEnd()
}

function Test-PatchOnlyCustomYaml {
  param([string]$Content)

  if ([string]::IsNullOrWhiteSpace($Content)) {
    return $true
  }

  $hasPatchRoot = $false
  foreach ($line in ($Content -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
      continue
    }

    if ($line -match '^\S') {
      if ($trimmed -eq 'patch:') {
        $hasPatchRoot = $true
        continue
      }
      return $false
    }
  }

  return $hasPatchRoot
}

function Get-WeaselManagedOllamaPatchLines {
  param(
    [string]$ApiUrl,
    [string]$ModelName
  )

  return @(
    '  # >>> Wisdom-Weasel managed Ollama config begin >>>',
    '  "llm/enabled": true',
    '  "llm/provider_type": openai',
    '  "llm/developer_mode": false',
    '  "llm/context_recent_words": 20',
    '  "llm/context_max_chars": 160',
    '  "llm/input_prediction_debounce_ms": 120',
    ('  "llm/openai/api_url": "{0}"' -f $ApiUrl),
    '  "llm/openai/api_key": ""',
    ('  "llm/openai/model": "{0}"' -f $ModelName),
    '  "llm/openai/max_tokens": 20',
    '  "llm/openai/temperature": "0.6"',
    '  # <<< Wisdom-Weasel managed Ollama config end <<<'
  )
}

function Set-WeaselCustomOllamaConfig {
  param(
    [string]$Path,
    [string]$ApiUrl,
    [string]$ModelName
  )

  $existingContent = if (Test-Path $Path) {
    Get-Content -Raw -Path $Path
  } else {
    ''
  }
  $contentWithoutManagedBlock = Remove-ManagedBlock -Content $existingContent
  $backupPath = Backup-File -Path $Path -Label 'pre-wisdom-weasel-ollama'
  $managedLines = Get-WeaselManagedOllamaPatchLines -ApiUrl $ApiUrl -ModelName $ModelName

  if ([string]::IsNullOrWhiteSpace($contentWithoutManagedBlock)) {
    $newContent = (@('patch:') + $managedLines) -join "`r`n"
  } elseif (Test-PatchOnlyCustomYaml -Content $contentWithoutManagedBlock) {
    $newContent = ($contentWithoutManagedBlock.TrimEnd(), ($managedLines -join "`r`n")) -join "`r`n"
  } else {
    $newContent = @(
      '# Wisdom-Weasel installer replaced this file with a managed Ollama config.',
      '# Restore your previous settings from the backup file created beside this file if needed.',
      'patch:'
    ) + $managedLines
    $newContent = $newContent -join "`r`n"
  }

  Set-Content -Path $Path -Value ($newContent.TrimEnd() + "`r`n") -Encoding utf8

  return $backupPath
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

function Get-DefaultLocalModelDirectory {
  param([string]$PreferredPath)

  $candidates = @(
    $PreferredPath,
    (Join-Path $env:USERPROFILE '.cache\huggingface\hub'),
    (Join-Path $env:USERPROFILE 'Downloads'),
    $env:USERPROFILE
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $PreferredPath
}

function Get-OllamaModelCatalog {
  return @(
    [pscustomobject]@{
      Model = 'qwen3:0.6b'
      Label = 'Qwen3 0.6B'
      Size = '523 MB'
      Hint = '最稳妥，适合轻薄本 / 低内存 / 纯 CPU'
    },
    [pscustomobject]@{
      Model = 'qwen3:1.7b'
      Label = 'Qwen3 1.7B'
      Size = '1.4 GB'
      Hint = '推荐均衡档，适合大多数日常办公机'
    },
    [pscustomobject]@{
      Model = 'qwen3:4b'
      Label = 'Qwen3 4B'
      Size = '2.5 GB'
      Hint = '更强预测质量，适合 16GB+ 内存或有独显'
    },
    [pscustomobject]@{
      Model = 'qwen3:8b'
      Label = 'Qwen3 8B'
      Size = '5.2 GB'
      Hint = '高质量档，适合高内存 / 6GB+ 显存机器'
    },
    [pscustomobject]@{
      Model = 'qwen3:14b'
      Label = 'Qwen3 14B'
      Size = '9.3 GB'
      Hint = '高性能机器可选，首装耗时和资源占用更高'
    }
  )
}

function Get-SystemHardwareProfile {
  try {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  } catch {
    $computer = $null
  }

  try {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
  } catch {
    $processors = @()
  }

  try {
    $videoControllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
  } catch {
    $videoControllers = @()
  }

  $totalRamBytes = 0
  if ($computer -and $computer.TotalPhysicalMemory) {
    [double]$totalRamBytes = $computer.TotalPhysicalMemory
  }
  $totalRamGb = [math]::Round($totalRamBytes / 1GB, 1)

  $logicalCores = 0
  $physicalCores = 0
  $cpuName = ''
  if ($processors.Count -gt 0) {
    $cpuName = ($processors | Select-Object -First 1).Name
    $logicalCores = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $physicalCores = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
  }

  $gpuEntries = @()
  foreach ($gpu in $videoControllers) {
    $name = [string]$gpu.Name
    if ([string]::IsNullOrWhiteSpace($name)) {
      continue
    }

    $ramGb = 0
    if ($gpu.AdapterRAM) {
      try {
        $ramGb = [math]::Round(([double]$gpu.AdapterRAM / 1GB), 1)
      } catch {
        $ramGb = 0
      }
    }

    $gpuEntries += [pscustomobject]@{
      Name = $name.Trim()
      RamGb = $ramGb
    }
  }

  $maxGpuRamGb = 0
  if ($gpuEntries.Count -gt 0) {
    $maxGpuRamGb = ($gpuEntries | Measure-Object -Property RamGb -Maximum).Maximum
  }

  $hasDedicatedGpu = $false
  foreach ($gpu in $gpuEntries) {
    if ($gpu.RamGb -ge 4 -or $gpu.Name -match 'NVIDIA|RTX|GTX|AMD Radeon RX|Arc ') {
      $hasDedicatedGpu = $true
      break
    }
  }

  return [pscustomobject]@{
    TotalRamGb = $totalRamGb
    CpuName = $cpuName
    LogicalCores = $logicalCores
    PhysicalCores = $physicalCores
    Gpus = $gpuEntries
    MaxGpuRamGb = $maxGpuRamGb
    HasDedicatedGpu = $hasDedicatedGpu
  }
}

function Get-RecommendedOllamaModel {
  param([pscustomobject]$HardwareProfile)

  if ($HardwareProfile.MaxGpuRamGb -ge 12 -or $HardwareProfile.TotalRamGb -ge 32) {
    return 'qwen3:14b'
  }
  if ($HardwareProfile.MaxGpuRamGb -ge 6 -or $HardwareProfile.TotalRamGb -ge 24) {
    return 'qwen3:8b'
  }
  if ($HardwareProfile.MaxGpuRamGb -ge 4 -or $HardwareProfile.TotalRamGb -ge 16) {
    return 'qwen3:4b'
  }
  if ($HardwareProfile.TotalRamGb -ge 10 -or $HardwareProfile.LogicalCores -ge 8) {
    return 'qwen3:1.7b'
  }
  return 'qwen3:0.6b'
}

function Get-HardwareSummaryText {
  param([pscustomobject]$HardwareProfile)

  $gpuText = if ($HardwareProfile.Gpus.Count -gt 0) {
    ($HardwareProfile.Gpus | ForEach-Object {
        if ($_.RamGb -gt 0) {
          '{0} ({1} GB)' -f $_.Name, $_.RamGb
        } else {
          $_.Name
        }
      }) -join '; '
  } else {
    '未识别到显卡信息'
  }

  return @(
    ('CPU: ' + ($(if ($HardwareProfile.CpuName) { $HardwareProfile.CpuName } else { '未知 CPU' }))),
    ('核心/线程: {0}/{1}' -f $HardwareProfile.PhysicalCores, $HardwareProfile.LogicalCores),
    ('内存: {0} GB' -f $HardwareProfile.TotalRamGb),
    ('显卡: ' + $gpuText),
    '说明：Ollama 会在支持的 CPU 上自动使用 AVX/AVX2 等指令集优化，无需额外手动开关。'
  ) -join "`r`n"
}

function Select-OllamaModel {
  param(
    [pscustomobject]$HardwareProfile,
    [string]$DefaultModel
  )

  Add-WinForms

  $catalog = Get-OllamaModelCatalog
  $recommendedModel = if ([string]::IsNullOrWhiteSpace($DefaultModel)) {
    Get-RecommendedOllamaModel -HardwareProfile $HardwareProfile
  } else {
    $DefaultModel
  }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = '选择 Ollama 预测模型'
  $form.Width = 760
  $form.Height = 520
  $form.StartPosition = 'CenterScreen'
  $form.TopMost = $true

  $summaryLabel = New-Object System.Windows.Forms.Label
  $summaryLabel.Left = 16
  $summaryLabel.Top = 16
  $summaryLabel.Width = 700
  $summaryLabel.Height = 110
  $summaryLabel.Text = "已检测硬件：`r`n$(Get-HardwareSummaryText -HardwareProfile $HardwareProfile)"
  $form.Controls.Add($summaryLabel)

  $recommendLabel = New-Object System.Windows.Forms.Label
  $recommendLabel.Left = 16
  $recommendLabel.Top = 132
  $recommendLabel.Width = 700
  $recommendLabel.Height = 24
  $recommendLabel.Text = "推荐模型：$recommendedModel（已按当前机器配置预选）"
  $form.Controls.Add($recommendLabel)

  $listBox = New-Object System.Windows.Forms.ListBox
  $listBox.Left = 16
  $listBox.Top = 164
  $listBox.Width = 700
  $listBox.Height = 180
  foreach ($entry in $catalog) {
    [void]$listBox.Items.Add(('{0}  |  {1}  |  {2}  |  {3}' -f $entry.Model, $entry.Label, $entry.Size, $entry.Hint))
  }
  [void]$listBox.Items.Add('custom  |  自定义  |  手动输入  |  输入任意 Ollama 模型名（例如 llama3.2:3b）')
  $form.Controls.Add($listBox)

  $customLabel = New-Object System.Windows.Forms.Label
  $customLabel.Left = 16
  $customLabel.Top = 356
  $customLabel.Width = 160
  $customLabel.Height = 24
  $customLabel.Text = '自定义模型名：'
  $form.Controls.Add($customLabel)

  $customText = New-Object System.Windows.Forms.TextBox
  $customText.Left = 176
  $customText.Top = 352
  $customText.Width = 340
  $customText.Enabled = $false
  $form.Controls.Add($customText)

  $tipLabel = New-Object System.Windows.Forms.Label
  $tipLabel.Left = 16
  $tipLabel.Top = 386
  $tipLabel.Width = 700
  $tipLabel.Height = 42
  $tipLabel.Text = '提示：模型越大，预测质量通常更好，但首次下载更慢、内存/显存占用更高。'
  $form.Controls.Add($tipLabel)

  $okButton = New-Object System.Windows.Forms.Button
  $okButton.Text = '确定'
  $okButton.Left = 520
  $okButton.Top = 432
  $okButton.Width = 90
  $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Controls.Add($okButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = '取消'
  $cancelButton.Left = 626
  $cancelButton.Top = 432
  $cancelButton.Width = 90
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($cancelButton)

  $form.AcceptButton = $okButton
  $form.CancelButton = $cancelButton

  $updateCustomState = {
    $selected = [string]$listBox.SelectedItem
    $isCustom = $selected.StartsWith('custom ')
    $customText.Enabled = $isCustom
    if (-not $isCustom) {
      $customText.Text = ''
    }
  }
  $listBox.add_SelectedIndexChanged($updateCustomState)

  $recommendedIndex = 0
  for ($index = 0; $index -lt $catalog.Count; $index++) {
    if ($catalog[$index].Model -eq $recommendedModel) {
      $recommendedIndex = $index
      break
    }
  }
  $listBox.SelectedIndex = $recommendedIndex
  & $updateCustomState

  $result = $form.ShowDialog()
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    throw '已取消选择 Ollama 模型。'
  }

  $selected = [string]$listBox.SelectedItem
  if ($selected.StartsWith('custom ')) {
    $customModel = $customText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($customModel)) {
      throw '自定义 Ollama 模型名不能为空。'
    }
    return $customModel
  }

  return ($selected -split '\s+\|\s+')[0].Trim()
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
自动下载并转换需要本机可用 Python 3，并且安装时可访问 Hugging Face。

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
  # Alpha 重排：Rime filter + alpha_input.dll
  alpha_rerank/enabled: $enabledValue
  alpha_rerank/config_path: "$AlphaConfigPath"
  alpha_rerank/dll_path: "$AlphaDllPath"
  alpha_rerank/max_candidates: 6
  alpha_rerank/context_max_chars: 64
  alpha_rerank/recent_tail_chars: 16
  alpha_rerank/order_prior_weight: 0.02
  # 长拼音输入时追加轻量输入覆盖先验，减少短词 / 单字意外上浮
  alpha_rerank/input_coverage_weight: 0.05
  # 默认不再用“固定第一候选”的旧 workaround
  alpha_rerank/preserve_first_min_chars: 0
  alpha_rerank/log_enabled: false
  # 留空时按 schema 默认路径写日志：%APPDATA%\Rime\alpha_rerank.log
  alpha_rerank/log_path: ""
  # 旧 HTTP 译码链路默认关闭，保留配置仅为兼容旧环境
  legacy_http_translator/enabled: false
  legacy_http_translator/api_url: "http://127.0.0.1:8080/predict"
  legacy_http_translator/request_timeout_ms: 1200
  legacy_http_translator/retry_cooldown_ms: 3000
  legacy_http_translator/min_syllable_count: 5
  legacy_http_translator/max_candidates: 5
  legacy_http_translator/initial_quality: 3.35
  legacy_http_translator/context_max_chars: 80
  legacy_http_translator/comment: "〔旧译〕"
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

function Find-OllamaExecutable {
  $candidates = [System.Collections.Generic.List[string]]::new()

  try {
    $command = Get-Command 'ollama.exe' -ErrorAction Stop
    [void]$candidates.Add($command.Source)
  } catch {
  }

  foreach ($path in @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
      (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Ollama\ollama.exe')
    )) {
    if ($path -and (Test-Path $path)) {
      [void]$candidates.Add($path)
    }
  }

  return $candidates | Select-Object -Unique | Select-Object -First 1
}

function Install-OllamaViaBootstrapScript {
  param([string]$InstallScriptUrl)

  $bootstrapScript = Join-Path $env:TEMP ("wisdom-weasel-ollama-bootstrap-" + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    Write-Host "==> 下载 Ollama 官方安装脚本: $InstallScriptUrl"
    Invoke-WebRequest -Uri $InstallScriptUrl -OutFile $bootstrapScript
    $shellExe = Get-PowerShellExecutable
    Invoke-NativeCommand -FilePath $shellExe -Arguments @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', $bootstrapScript
    )
  } finally {
    Remove-Item -LiteralPath $bootstrapScript -Force -ErrorAction SilentlyContinue
  }
}

function Install-OllamaViaInstallerExe {
  param([string]$InstallerUrl)

  $installerPath = Join-Path $env:TEMP ("wisdom-weasel-ollama-setup-" + [guid]::NewGuid().ToString('N') + '.exe')
  try {
    Write-Host "==> 下载 Ollama 安装器: $InstallerUrl"
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installerPath
    Write-Warning '官方 Ollama bootstrap 脚本安装失败，回退到下载并启动 OllamaSetup.exe。'
    $process = Start-Process -FilePath $installerPath -Wait -PassThru
    if ($process.ExitCode -ne 0) {
      throw "OllamaSetup.exe 安装失败，exit=$($process.ExitCode)"
    }
  } finally {
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-OllamaInstalled {
  param(
    [string]$InstallScriptUrl,
    [string]$InstallerUrl
  )

  $ollamaExe = Find-OllamaExecutable
  if ($ollamaExe) {
    return $ollamaExe
  }

  try {
    Install-OllamaViaBootstrapScript -InstallScriptUrl $InstallScriptUrl
  } catch {
    Write-Warning ("官方 Ollama 安装脚本失败：{0}" -f $_.Exception.Message)
    Install-OllamaViaInstallerExe -InstallerUrl $InstallerUrl
  }

  $ollamaExe = Find-OllamaExecutable
  if (-not $ollamaExe) {
    throw 'Ollama 安装完成后仍未找到 ollama.exe。'
  }

  return $ollamaExe
}

function Test-OllamaApiReady {
  param([string]$BaseUrl)

  try {
    $null = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/api/version') -Method Get -TimeoutSec 5
    return $true
  } catch {
    return $false
  }
}

function Wait-OllamaApiReady {
  param(
    [string]$BaseUrl,
    [int]$TimeoutSec = 60
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-OllamaApiReady -BaseUrl $BaseUrl) {
      return $true
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Ensure-OllamaApiReady {
  param(
    [string]$OllamaExe,
    [string]$BaseUrl
  )

  if (Wait-OllamaApiReady -BaseUrl $BaseUrl -TimeoutSec 10) {
    return
  }

  Write-Host '==> 启动 Ollama 本地服务'
  Start-Process -FilePath $OllamaExe -ArgumentList 'serve' -WindowStyle Hidden | Out-Null

  if (-not (Wait-OllamaApiReady -BaseUrl $BaseUrl -TimeoutSec 90)) {
    throw "Ollama 服务未能在预期时间内启动：$BaseUrl"
  }
}

function Test-OllamaModelInstalled {
  param(
    [string]$BaseUrl,
    [string]$ModelName
  )

  try {
    $result = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/api/tags') -Method Get -TimeoutSec 10
    foreach ($model in @($result.models)) {
      if ($null -eq $model) {
        continue
      }

      if ($model.name -eq $ModelName -or $model.model -eq $ModelName) {
        return $true
      }
    }
  } catch {
  }

  return $false
}

function Ensure-OllamaModelInstalled {
  param(
    [string]$OllamaExe,
    [string]$BaseUrl,
    [string]$ModelName
  )

  if (Test-OllamaModelInstalled -BaseUrl $BaseUrl -ModelName $ModelName) {
    return
  }

  Write-Host "==> 拉取 Ollama 预测模型：$ModelName"
  Invoke-NativeCommand -FilePath $OllamaExe -Arguments @('pull', $ModelName)

  if (-not (Test-OllamaModelInstalled -BaseUrl $BaseUrl -ModelName $ModelName)) {
    throw "Ollama 模型拉取后仍不可见：$ModelName"
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

function Remove-LegacyAlphaSourceModel {
  param([string]$ModelRoot)

  $layout = Get-AlphaModelLayout -ModelRoot $ModelRoot
  if (Test-Path $layout.HfDir) {
    Write-Host "==> 清理安装目录中的原始 HF 模型缓存: $($layout.HfDir)"
    Remove-Item -LiteralPath $layout.HfDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Open-GuiGuide {
  param(
    [string]$TargetDir,
    [string]$RimeDir,
    [bool]$AlphaEnabled,
    [string]$ModelStatus,
    [string]$ReleaseTagValue,
    [string]$OllamaStatus,
    [string]$WeaselCustomBackupPath
  )

  Add-WinForms

  $alphaStatus = if ($AlphaEnabled) { '已启用' } else { '未启用' }
  $backupDisplay = if ([string]::IsNullOrWhiteSpace($WeaselCustomBackupPath)) {
    '本次未生成备份（原文件不存在或为空）'
  } else {
    $WeaselCustomBackupPath
  }
  $message = @"
Wisdom-Weasel 已安装完成。

Release：
$ReleaseTagValue

Alpha 重排：
$alphaStatus

模型状态：
$ModelStatus

Ollama 预测：
$OllamaStatus

weasel.custom.yaml 备份：
$backupDisplay

建议下一步：
1. 打开“小狼毫输入法设定”
2. 勾选 wanxiang / wanxiang_pro
3. 如需修改 Ollama / LLM，请编辑：
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
$OllamaBaseUrl = $OllamaBaseUrl.TrimEnd('/')

$hardwareProfile = $null
if (-not $SkipOllamaSetup) {
  $hardwareProfile = Get-SystemHardwareProfile
  if ([string]::IsNullOrWhiteSpace($OllamaModel)) {
    if ($OllamaModelSelection -eq 'prompt') {
      $OllamaModel = Select-OllamaModel -HardwareProfile $hardwareProfile -DefaultModel (Get-RecommendedOllamaModel -HardwareProfile $hardwareProfile)
    } else {
      $OllamaModel = Get-RecommendedOllamaModel -HardwareProfile $hardwareProfile
    }
  }
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
  $LocalModelDir = Select-LocalModelDirectory -DefaultPath (Get-DefaultLocalModelDirectory -PreferredPath $targetModelLayout.HfDir)
}

if ($effectiveModelSetup -ne 'skip') {
  try {
    $pythonPath = Ensure-ModelConversionPython -VenvDir $modelToolsVenv
    Ensure-ModelConversionDependencies -PythonPath $pythonPath

    $modelSourceDir = ''
    if ($effectiveModelSetup -eq 'auto') {
      Write-Host "==> 从 Hugging Face 下载推荐 Alpha 模型：$AlphaModelId"
      $downloadedModelDir = Join-Path $modelWorkDir 'hf-source-model'
      Download-HuggingFaceModel -PythonPath $pythonPath -ModelId $AlphaModelId -Destination $downloadedModelDir
      $modelSourceDir = $downloadedModelDir
      $modelStatus = "已从 Hugging Face 下载到临时目录并开始转换：$AlphaModelId"
    } elseif ($effectiveModelSetup -eq 'local') {
      if (!(Test-Path $LocalModelDir)) {
        throw "本地模型目录不存在：$LocalModelDir"
      }
      $modelSourceDir = $LocalModelDir
      $modelStatus = "已使用本地模型目录开始转换：$LocalModelDir"
    }

    Install-ConvertedAlphaModel -PythonPath $pythonPath -SourceRoot $sourceRoot -ModelSourceDir $modelSourceDir -TargetModelRoot $targetModelRoot -WorkRoot $modelWorkDir
    Remove-LegacyAlphaSourceModel -ModelRoot $targetModelRoot

    if ($effectiveModelSetup -eq 'auto') {
      $modelStatus = "Alpha 模型已从 Hugging Face 下载到临时目录并本地转换完成，仅保留 ONNX / LMDB：$AlphaModelId"
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
$weaselCustomBackupPath = $null
$ollamaStatus = '已跳过 Ollama 预测安装。'
$ollamaChatUrl = Get-OllamaChatCompletionsUrl -BaseUrl $OllamaBaseUrl

if (-not $SkipOllamaSetup) {
  Write-Host '==> 安装 Ollama 预测运行时'
  $ollamaExe = Ensure-OllamaInstalled -InstallScriptUrl $OllamaInstallScriptUrl -InstallerUrl $OllamaInstallerUrl
  Ensure-OllamaApiReady -OllamaExe $ollamaExe -BaseUrl $OllamaBaseUrl
  Ensure-OllamaModelInstalled -OllamaExe $ollamaExe -BaseUrl $OllamaBaseUrl -ModelName $OllamaModel
  $weaselCustomBackupPath = Set-WeaselCustomOllamaConfig -Path $weaselCustomPath -ApiUrl $ollamaChatUrl -ModelName $OllamaModel

  $backupSuffix = if ($weaselCustomBackupPath) {
    "；已备份旧配置：$weaselCustomBackupPath"
  } else {
    '；原本不存在 weasel.custom.yaml，本次已自动创建'
  }
  $ollamaStatus = "已安装/确认 Ollama，本地 API 就绪，模型已拉取：$OllamaModel$backupSuffix"
} elseif (!(Test-Path $weaselCustomPath)) {
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
  Open-GuiGuide -TargetDir $InstallDir -RimeDir $RimeUserDir -AlphaEnabled $alphaEnabled -ModelStatus $modelStatus -ReleaseTagValue $release.tag_name -OllamaStatus $ollamaStatus -WeaselCustomBackupPath $weaselCustomBackupPath
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '安装完成。'
Write-Host "程序目录: $InstallDir"
Write-Host "Rime 用户目录: $RimeUserDir"
Write-Host "使用 release: $($release.tag_name)"
Write-Host "源码来源: $SourceRef"
Write-Host "Alpha 模型状态: $modelStatus"
if (-not [string]::IsNullOrWhiteSpace($OllamaModel)) {
  Write-Host "Ollama 模型: $OllamaModel"
}
Write-Host "Ollama 状态: $ollamaStatus"
Write-Host "weasel.custom.yaml: $weaselCustomPath"
if ($weaselCustomBackupPath) {
  Write-Host "weasel.custom.yaml 备份: $weaselCustomBackupPath"
}
if ($alphaEnabled) {
  Write-Host "Alpha 配置: $rimeAlphaConfigPath"
} else {
  Write-Host 'Alpha 重排当前未启用。'
}
