[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [ValidateSet('x64', 'Win32')]
    [string]$Platform = 'x64',

    [string]$OutputPath = 'compile_commands.json'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$tlogRoot = Join-Path $projectRoot ("msbuild/{0}/{1}" -f $Configuration, $Platform)

if (-not (Test-Path $tlogRoot)) {
    throw "tlog 目录不存在: $tlogRoot"
}

function Get-VsInstallPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "未找到 vswhere.exe: $vswhere"
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installPath) {
        throw "未找到可用的 Visual Studio C++ 工具链"
    }

    return $installPath.Trim()
}

function Get-ClPath([string]$vsInstallPath, [string]$platform) {
    $msvcRoot = Join-Path $vsInstallPath 'VC\Tools\MSVC'
    if (-not (Test-Path $msvcRoot)) {
        throw "未找到 MSVC 工具目录: $msvcRoot"
    }

    $latestMsvc = Get-ChildItem $msvcRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latestMsvc) {
        throw "未找到 MSVC 版本目录: $msvcRoot"
    }

    $targetArch = if ($platform -eq 'Win32') { 'x86' } else { 'x64' }
    $clPath = Join-Path $latestMsvc.FullName ("bin\Hostx64\{0}\cl.exe" -f $targetArch)
    if (-not (Test-Path $clPath)) {
        throw "未找到 cl.exe: $clPath"
    }

    return $clPath
}

$vsInstallPath = Get-VsInstallPath
$clPath = Get-ClPath -vsInstallPath $vsInstallPath -platform $Platform

$entries = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$tlogFiles = Get-ChildItem $tlogRoot -Recurse -Filter 'CL.command.1.tlog' | Sort-Object FullName

foreach ($tlog in $tlogFiles) {
    $currentSource = $null
    foreach ($rawLine in Get-Content $tlog.FullName) {
        $line = $rawLine.Trim()
        if (-not $line) {
            continue
        }

        if ($line.StartsWith('^')) {
            $candidate = $line.Substring(1).Trim()
            if ($candidate) {
                $currentSource = $candidate
            }
            continue
        }

        if (-not $currentSource) {
            continue
        }

        $command = $line
        if ($command -notmatch '(^|[\\/])cl\.exe(\s|$)') {
            $command = ('"{0}" {1}' -f $clPath, $command)
        }

        $normalizedSource = [System.IO.Path]::GetFullPath($currentSource)
        $entry = [ordered]@{
            directory = $projectRoot
            file      = $normalizedSource
            command   = $command
        }
        $entries[$normalizedSource] = $entry
        $currentSource = $null
    }
}

if ($entries.Count -eq 0) {
    throw "未从 $tlogRoot 解析到任何编译命令"
}

$outputFile = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path $projectRoot $OutputPath
}

$outputDir = Split-Path -Parent $outputFile
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$json = $entries.Values | ConvertTo-Json -Depth 6
Set-Content -Path $outputFile -Value $json -Encoding UTF8

Write-Host ("Generated {0} entries to {1}" -f $entries.Count, $outputFile)
Write-Host ("Visual Studio: {0}" -f $vsInstallPath)
Write-Host ("Compiler: {0}" -f $clPath)
