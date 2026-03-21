param(
  [string]$Version = "",
  [switch]$SkipArchive
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

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = Get-ProductVersion -PropsPath (Join-Path $root 'weasel.props')
}

$distRoot = Join-Path $root 'archives'
$bundleRoot = Join-Path $distRoot ("Wisdom-Weasel-" + $Version)
if (Test-Path $bundleRoot) {
  Remove-Item $bundleRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $bundleRoot | Out-Null

Write-Host "==> 组装发行目录: $bundleRoot"

Copy-DirectoryContents -Source (Join-Path $root 'output') -Destination (Join-Path $bundleRoot 'output') -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj', '.iobj', '.ipdb')
Copy-DirectoryContents -Source (Join-Path $root 'third_party\rime_wanxiang') -Destination (Join-Path $bundleRoot 'third_party\rime_wanxiang')
Copy-DirectoryContents -Source (Join-Path $root 'alpha_backend\model\qwen3-0.6b-onnx-int8') -Destination (Join-Path $bundleRoot 'alpha_backend\model\qwen3-0.6b-onnx-int8')
Copy-DirectoryContents -Source (Join-Path $root 'alpha_backend\model\qwen3-0.6b-embeddings_lmdb') -Destination (Join-Path $bundleRoot 'alpha_backend\model\qwen3-0.6b-embeddings_lmdb')
Copy-DirectoryContents -Source (Join-Path $root 'alpha_backend\target\release') -Destination (Join-Path $bundleRoot 'alpha_backend\target\release') -ExcludeExtensions @('.pdb', '.exp', '.lib', '.obj')

Copy-Item (Join-Path $root 'alpha_backend\config.example.toml') -Destination (Join-Path $bundleRoot 'alpha_backend\config.example.toml') -Force
Copy-Item (Join-Path $root 'README.md') -Destination (Join-Path $bundleRoot 'README.md') -Force
Copy-Item (Join-Path $root 'docs\final_architecture.md') -Destination (Join-Path $bundleRoot 'FINAL_ARCHITECTURE.md') -Force

New-Item -ItemType Directory -Force -Path (Join-Path $bundleRoot 'scripts') | Out-Null
Copy-Item (Join-Path $root 'scripts\Install-RimeWanxiang.ps1') -Destination (Join-Path $bundleRoot 'scripts\Install-RimeWanxiang.ps1') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.ps1') -Destination (Join-Path $bundleRoot 'scripts\Install-Wisdom-Weasel.ps1') -Force
Copy-Item (Join-Path $root 'scripts\Install-Wisdom-Weasel.cmd') -Destination (Join-Path $bundleRoot 'Install-Wisdom-Weasel.cmd') -Force

if (-not $SkipArchive) {
  $archivePath = Join-Path $distRoot ("Wisdom-Weasel-" + $Version + "-bundle.7z")
  if (Test-Path $archivePath) {
    Remove-Item $archivePath -Force
  }
  $sevenZip = Join-Path $root '7z.exe'
  if (!(Test-Path $sevenZip)) {
    throw "7z.exe not found: $sevenZip"
  }
  Write-Host "==> 生成压缩包: $archivePath"
  & $sevenZip a -t7z -mx=3 $archivePath (Join-Path $bundleRoot '*') | Out-Host
}

Write-Host ''
Write-Host "发行目录已生成: $bundleRoot"
