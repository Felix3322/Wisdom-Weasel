param(
  [string]$Version = ""
)

$ErrorActionPreference = 'Stop'

function Get-ProductVersion {
  param([string]$PropsPath)

  if (!(Test-Path $PropsPath)) {
    return "dev"
  }

  $raw = Get-Content -Raw -Path $PropsPath
  $m = [regex]::Match($raw, '<PRODUCT_VERSION>([^<]+)</PRODUCT_VERSION>')
  if ($m.Success) {
    return $m.Groups[1].Value.Trim()
  }
  return "dev"
}

function Copy-DirectoryContents {
  param(
    [string]$Source,
    [string]$Destination,
    [string[]]$ExcludeExtensions = @()
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Recurse -Force | ForEach-Object {
    $relative = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative
    if ($_.PSIsContainer) {
      New-Item -ItemType Directory -Force -Path $target | Out-Null
      return
    }
    if ($ExcludeExtensions -contains $_.Extension.ToLowerInvariant()) {
      return
    }
    $parent = Split-Path -Parent $target
    if ($parent) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

function New-ZipArchive {
  param(
    [string]$ArchivePath,
    [string]$SourceRoot,
    [string]$SevenZipPath = ''
  )

  if (Test-Path $ArchivePath) {
    Remove-Item $ArchivePath -Force
  }

  if ($SevenZipPath -and (Test-Path $SevenZipPath)) {
    & $SevenZipPath a -mx=9 $ArchivePath (Join-Path $SourceRoot '*') | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $ArchivePath)) {
      return
    }
    Write-Warning "7z 打包失败，改用 Compress-Archive：$ArchivePath"
    Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
  }

  Compress-Archive -Path (Join-Path $SourceRoot '*') -DestinationPath $ArchivePath -CompressionLevel Fastest
}

function New-EmptyDir {
  param([string]$Path)
  if (Test-Path $Path) {
    Remove-Item $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function New-IExpressInstaller {
  param(
    [string]$SourceRoot,
    [string]$TargetExe,
    [string]$FriendlyName = 'Wisdom-Weasel Installer'
  )

  $iexpress = Get-Command iexpress.exe -ErrorAction Stop
  $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wisdom-weasel-iexpress-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

  try {
    $sedPath = Join-Path $workRoot 'installer.sed'
    $sourceWithSlash = $SourceRoot.TrimEnd('\') + '\'

    $fileEntries = Get-ChildItem -LiteralPath $SourceRoot -File | Sort-Object Name
    if ($fileEntries.Count -eq 0) {
      throw "IExpress 源目录为空：$SourceRoot"
    }

    $stringsLines = @(
      'InstallPrompt=',
      'DisplayLicense=',
      'FinishMessage=',
      ('TargetName=' + $TargetExe),
      ('FriendlyName=' + $FriendlyName),
      'AppLaunched=cmd.exe /c Install-Wisdom-Weasel.cmd',
      'PostInstallCmd=<None>',
      'AdminQuietInstCmd=cmd.exe /c Install-Wisdom-Weasel.cmd',
      'UserQuietInstCmd=cmd.exe /c Install-Wisdom-Weasel.cmd'
    )

    $sourceFileLines = @()
    for ($i = 0; $i -lt $fileEntries.Count; $i++) {
      $label = 'FILE' + $i
      $stringsLines += ('{0}={1}' -f $label, $fileEntries[$i].Name)
      $sourceFileLines += ('%{0}%=' -f $label)
    }

    $sedLines = @(
      '[Version]',
      'Class=IEXPRESS',
      'SEDVersion=3',
      '[Options]',
      'PackagePurpose=InstallApp',
      'ShowInstallProgramWindow=1',
      'HideExtractAnimation=1',
      'UseLongFileName=1',
      'InsideCompressed=0',
      'CAB_FixedSize=0',
      'CAB_ResvCodeSigning=0',
      'RebootMode=N',
      'InstallPrompt=%InstallPrompt%',
      'DisplayLicense=%DisplayLicense%',
      'FinishMessage=%FinishMessage%',
      'TargetName=%TargetName%',
      'FriendlyName=%FriendlyName%',
      'AppLaunched=%AppLaunched%',
      'PostInstallCmd=%PostInstallCmd%',
      'AdminQuietInstCmd=%AdminQuietInstCmd%',
      'UserQuietInstCmd=%UserQuietInstCmd%',
      'SourceFiles=SourceFiles',
      '[Strings]'
    ) + $stringsLines + @(
      '[SourceFiles]',
      ('SourceFiles0=' + $sourceWithSlash),
      '[SourceFiles0]'
    ) + $sourceFileLines

    Set-Content -Path $sedPath -Value ($sedLines -join "`r`n") -Encoding Ascii

    if (Test-Path $TargetExe) {
      Remove-Item $TargetExe -Force
    }

    $process = Start-Process -FilePath $iexpress.Source -ArgumentList '/N', $sedPath -Wait -PassThru
    if ($process.ExitCode -ne 0) {
      throw "IExpress 打包失败，exit=$($process.ExitCode)"
    }
    if (!(Test-Path $TargetExe)) {
      throw "IExpress 未生成目标文件：$TargetExe"
    }
  } finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = Get-ProductVersion -PropsPath (Join-Path $root 'weasel.props')
}
$sevenZipPath = Join-Path $root '7z.exe'

$distRoot = Join-Path $root 'archives'
New-Item -ItemType Directory -Force -Path $distRoot | Out-Null

$installerRoot = Join-Path $distRoot ("Wisdom-Weasel-installer-" + $Version)
$bootstrapRoot = Join-Path $distRoot ("Wisdom-Weasel-bootstrap-" + $Version)
$runtimeRoot = Join-Path $distRoot ("Wisdom-Weasel-runtime-" + $Version)

foreach ($dir in @($installerRoot, $bootstrapRoot, $runtimeRoot)) {
  New-EmptyDir -Path $dir
}

Write-Host "==> 生成 installer exe 工作目录"
Copy-Item (Join-Path $root 'README.md') -Destination (Join-Path $installerRoot 'README.md') -Force
Copy-Item (Join-Path $root 'docs\final_architecture.md') -Destination (Join-Path $installerRoot 'FINAL_ARCHITECTURE.md') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.ps1') -Destination (Join-Path $installerRoot 'Install-Wisdom-Weasel.ps1') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.cmd') -Destination (Join-Path $installerRoot 'Install-Wisdom-Weasel.cmd') -Force

Write-Host "==> 生成 bootstrap 包目录"
New-Item -ItemType Directory -Force -Path (Join-Path $bootstrapRoot 'scripts') | Out-Null
Copy-Item (Join-Path $root 'README.md') -Destination (Join-Path $bootstrapRoot 'README.md') -Force
Copy-Item (Join-Path $root 'docs\final_architecture.md') -Destination (Join-Path $bootstrapRoot 'FINAL_ARCHITECTURE.md') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.ps1') -Destination (Join-Path $bootstrapRoot 'scripts\Install-Wisdom-Weasel.ps1') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.cmd') -Destination (Join-Path $bootstrapRoot 'Install-Wisdom-Weasel.cmd') -Force

Write-Host "==> 生成 runtime 包目录"
Copy-DirectoryContents -Source (Join-Path $root 'output') -Destination (Join-Path $runtimeRoot 'output') -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj', '.iobj', '.ipdb')
Copy-DirectoryContents -Source (Join-Path $root 'alpha_backend\target\release') -Destination (Join-Path $runtimeRoot 'alpha_backend\target\release') -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj')

$installerExe = Join-Path $distRoot ("Wisdom-Weasel-installer-" + $Version + ".exe")
$bootstrapArchive = Join-Path $distRoot ("Wisdom-Weasel-bootstrap-" + $Version + ".zip")
$runtimeArchive = Join-Path $distRoot ("Wisdom-Weasel-runtime-" + $Version + ".zip")

Write-Host "==> 生成 installer exe"
New-IExpressInstaller -SourceRoot $installerRoot -TargetExe $installerExe

Write-Host "==> 打包 bootstrap 资产"
New-ZipArchive -ArchivePath $bootstrapArchive -SourceRoot $bootstrapRoot -SevenZipPath $sevenZipPath

Write-Host "==> 打包 runtime 资产"
New-ZipArchive -ArchivePath $runtimeArchive -SourceRoot $runtimeRoot -SevenZipPath $sevenZipPath

Write-Host ''
Write-Host "Installer: $installerExe"
Write-Host "Bootstrap: $bootstrapArchive"
Write-Host "Runtime:   $runtimeArchive"
Write-Host ''
Write-Host '说明：'
Write-Host '- Release 现在可放一个安装器 EXE + 两个小包。'
Write-Host '- Release 不再包含 Alpha 模型资产。'
Write-Host '- Alpha 模型改为由安装器 EXE 在安装时下载并本机转换。'
