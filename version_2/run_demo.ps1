param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

Set-Location $ProjectRoot
$env:IME_DEMO_HOST = $BindHost
$env:IME_DEMO_PORT = "$Port"

Write-Host "Project root: $ProjectRoot"
Write-Host "Starting demo at http://$BindHost`:$Port"
python -u .\html_demo\main.py
