param(
  [string]$Version = "",
  [ValidateSet('auto', 'nsis', 'iexpress')]
  [string]$InstallerBackend = 'auto'
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

function Get-NumericVersion {
  param([string]$VersionText)

  $parts = [System.Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches($VersionText, '\d+')) {
    [void]$parts.Add($m.Value)
    if ($parts.Count -ge 4) {
      break
    }
  }

  while ($parts.Count -lt 4) {
    [void]$parts.Add('0')
  }

  return ($parts.ToArray()[0..3] -join '.')
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
    & $SevenZipPath a -tzip -mx=9 $ArchivePath (Join-Path $SourceRoot '*') | Out-Null
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

function Get-NsisCompiler {
  $candidates = [System.Collections.Generic.List[string]]::new()

  try {
    $command = Get-Command 'makensis.exe' -ErrorAction Stop
    [void]$candidates.Add($command.Source)
  } catch {
  }

  if (${env:ProgramFiles(x86)}) {
    $path = Join-Path ${env:ProgramFiles(x86)} 'NSIS\Bin\makensis.exe'
    if (Test-Path $path) {
      [void]$candidates.Add($path)
    }
  }

  if ($env:ProgramFiles) {
    $path = Join-Path $env:ProgramFiles 'NSIS\Bin\makensis.exe'
    if (Test-Path $path) {
      [void]$candidates.Add($path)
    }
  }

  return $candidates | Select-Object -Unique | Select-Object -First 1
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

function New-NsisInstaller {
  param(
    [string]$SourceRoot,
    [string]$TargetExe,
    [string]$FriendlyName,
    [string]$VersionText,
    [string]$TemplatePath,
    [string]$LicensePath,
    [string]$IconPath
  )

  $makensis = Get-NsisCompiler
  if (-not $makensis) {
    throw '未找到 makensis.exe，请先安装 NSIS，或改用 -InstallerBackend iexpress。'
  }
  if (!(Test-Path $TemplatePath)) {
    throw "缺少 NSIS 模板：$TemplatePath"
  }

  if (Test-Path $TargetExe) {
    Remove-Item $TargetExe -Force
  }

  $arguments = @(
    '/V2',
    "/DAPP_NAME=$FriendlyName",
    "/DAPP_VERSION=$VersionText",
    "/DAPP_VERSION_NUMERIC=$(Get-NumericVersion -VersionText $VersionText)",
    "/DOUTPUT_FILE=$TargetExe",
    "/DSOURCE_ROOT=$SourceRoot",
    "/DLICENSE_FILE=$LicensePath",
    "/DICON_FILE=$IconPath",
    $TemplatePath
  )

  & $makensis @arguments | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "NSIS 打包失败，exit=$LASTEXITCODE"
  }
  if (!(Test-Path $TargetExe)) {
    throw "NSIS 未生成目标文件：$TargetExe"
  }
}

function New-ReleaseInstaller {
  param(
    [ValidateSet('auto', 'nsis', 'iexpress')]
    [string]$Backend,
    [string]$SourceRoot,
    [string]$TargetExe,
    [string]$FriendlyName,
    [string]$VersionText,
    [string]$TemplatePath,
    [string]$LicensePath,
    [string]$IconPath
  )

  switch ($Backend) {
    'nsis' {
      New-NsisInstaller -SourceRoot $SourceRoot -TargetExe $TargetExe -FriendlyName $FriendlyName -VersionText $VersionText -TemplatePath $TemplatePath -LicensePath $LicensePath -IconPath $IconPath
      return 'nsis'
    }
    'iexpress' {
      New-IExpressInstaller -SourceRoot $SourceRoot -TargetExe $TargetExe -FriendlyName $FriendlyName
      return 'iexpress'
    }
    default {
      if (Get-NsisCompiler) {
        New-NsisInstaller -SourceRoot $SourceRoot -TargetExe $TargetExe -FriendlyName $FriendlyName -VersionText $VersionText -TemplatePath $TemplatePath -LicensePath $LicensePath -IconPath $IconPath
        return 'nsis'
      }

      Write-Warning '未找到 NSIS，回退到 IExpress。建议先运行 install_nsis.bat，以生成更好的 GUI 安装器。'
      New-IExpressInstaller -SourceRoot $SourceRoot -TargetExe $TargetExe -FriendlyName $FriendlyName
      return 'iexpress'
    }
  }
}

function Remove-CurrentVersionModelAssets {
  param(
    [string]$DistRoot,
    [string]$VersionText
  )

  $staleItems = Get-ChildItem -LiteralPath $DistRoot -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like ("Wisdom-Weasel-model-*-" + $VersionText + "*")
  }

  foreach ($item in $staleItems) {
    Write-Host "==> 删除旧的模型发行版资产: $($item.FullName)"
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
  }
}

function Write-ReleaseAssetManifest {
  param(
    [string]$Path,
    [string]$VersionText,
    [string]$InstallerBackendUsed,
    [string[]]$Assets
  )

  $lines = @(
    "Wisdom-Weasel release assets ($VersionText)",
    '',
    'Upload ONLY these files:',
    ''
  )

  foreach ($asset in $Assets) {
    $lines += ('- ' + $asset)
  }

  $lines += @(
    '',
    'Do NOT upload any Wisdom-Weasel-model-* files.',
    'Alpha models are downloaded from Hugging Face during installation and converted locally on the target machine.',
    '',
    ('Installer backend used: ' + $InstallerBackendUsed)
  )

  Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding utf8
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = Get-ProductVersion -PropsPath (Join-Path $root 'weasel.props')
}

$sevenZipPath = Join-Path $root '7z.exe'
$templatePath = Join-Path $root 'scripts\Wisdom-Weasel-bootstrap-installer.nsi'
$licensePath = Join-Path $root 'LICENSE.txt'
$iconPath = Join-Path $root 'resource\weasel.ico'

$distRoot = Join-Path $root 'archives'
New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
Remove-CurrentVersionModelAssets -DistRoot $distRoot -VersionText $Version

$installerRoot = Join-Path $distRoot ("Wisdom-Weasel-installer-" + $Version)
$bootstrapRoot = Join-Path $distRoot ("Wisdom-Weasel-bootstrap-" + $Version)
$runtimeRoot = Join-Path $distRoot ("Wisdom-Weasel-runtime-" + $Version)

foreach ($dir in @($installerRoot, $bootstrapRoot, $runtimeRoot)) {
  New-EmptyDir -Path $dir
}

Write-Host "==> 生成 installer 工作目录"
Copy-Item (Join-Path $root 'README.md') -Destination (Join-Path $installerRoot 'README.md') -Force
Copy-Item (Join-Path $root 'docs\final_architecture.md') -Destination (Join-Path $installerRoot 'FINAL_ARCHITECTURE.md') -Force
Copy-Item (Join-Path $root 'LICENSE.txt') -Destination (Join-Path $installerRoot 'LICENSE.txt') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.ps1') -Destination (Join-Path $installerRoot 'Install-Wisdom-Weasel.ps1') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.cmd') -Destination (Join-Path $installerRoot 'Install-Wisdom-Weasel.cmd') -Force

Write-Host "==> 生成 bootstrap 包目录"
New-Item -ItemType Directory -Force -Path (Join-Path $bootstrapRoot 'scripts') | Out-Null
Copy-Item (Join-Path $root 'README.md') -Destination (Join-Path $bootstrapRoot 'README.md') -Force
Copy-Item (Join-Path $root 'docs\final_architecture.md') -Destination (Join-Path $bootstrapRoot 'FINAL_ARCHITECTURE.md') -Force
Copy-Item (Join-Path $root 'LICENSE.txt') -Destination (Join-Path $bootstrapRoot 'LICENSE.txt') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.ps1') -Destination (Join-Path $bootstrapRoot 'scripts\Install-Wisdom-Weasel.ps1') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.cmd') -Destination (Join-Path $bootstrapRoot 'Install-Wisdom-Weasel.cmd') -Force

Write-Host "==> 生成 runtime 包目录"
Copy-DirectoryContents -Source (Join-Path $root 'output') -Destination (Join-Path $runtimeRoot 'output') -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj', '.iobj', '.ipdb')
Copy-DirectoryContents -Source (Join-Path $root 'alpha_backend\target\release') -Destination (Join-Path $runtimeRoot 'alpha_backend\target\release') -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj')

$installerExe = Join-Path $distRoot ("Wisdom-Weasel-installer-" + $Version + ".exe")
$bootstrapArchive = Join-Path $distRoot ("Wisdom-Weasel-bootstrap-" + $Version + ".zip")
$runtimeArchive = Join-Path $distRoot ("Wisdom-Weasel-runtime-" + $Version + ".zip")
$manifestPath = Join-Path $distRoot ("Wisdom-Weasel-release-assets-" + $Version + ".txt")

Write-Host "==> 生成 installer exe"
$installerBackendUsed = New-ReleaseInstaller `
  -Backend $InstallerBackend `
  -SourceRoot $installerRoot `
  -TargetExe $installerExe `
  -FriendlyName 'Wisdom-Weasel Installer' `
  -VersionText $Version `
  -TemplatePath $templatePath `
  -LicensePath $licensePath `
  -IconPath $iconPath

Write-Host "==> 打包 bootstrap 资产"
New-ZipArchive -ArchivePath $bootstrapArchive -SourceRoot $bootstrapRoot -SevenZipPath $sevenZipPath

Write-Host "==> 打包 runtime 资产"
New-ZipArchive -ArchivePath $runtimeArchive -SourceRoot $runtimeRoot -SevenZipPath $sevenZipPath

Write-ReleaseAssetManifest -Path $manifestPath -VersionText $Version -InstallerBackendUsed $installerBackendUsed -Assets @(
  [System.IO.Path]::GetFileName($installerExe),
  [System.IO.Path]::GetFileName($bootstrapArchive),
  [System.IO.Path]::GetFileName($runtimeArchive)
)

Write-Host ''
Write-Host "Installer: $installerExe"
Write-Host "Bootstrap: $bootstrapArchive"
Write-Host "Runtime:   $runtimeArchive"
Write-Host "Manifest:  $manifestPath"
Write-Host "Backend:   $installerBackendUsed"
Write-Host ''
Write-Host '说明：'
Write-Host '- Release 只需要上传 manifest 里列出的 3 个资产。'
Write-Host '- Build 脚本会删除当前版本残留的 Wisdom-Weasel-model-* 资产。'
Write-Host '- Alpha 模型不再出现在发行版中，而是在安装时从 Hugging Face 下载到临时目录并本机转换。'
