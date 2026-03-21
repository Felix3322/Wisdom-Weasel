$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root '.alpha_hf_test_backend.pid'

if (!(Test-Path $pidFile)) {
  Write-Host 'alpha HF test backend is not running.'
  exit 0
}

$targetPid = Get-Content $pidFile -ErrorAction SilentlyContinue
if (!$targetPid) {
  Remove-Item $pidFile -ErrorAction SilentlyContinue
  Write-Host 'alpha HF test backend pid file was empty and has been removed.'
  exit 0
}

$process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
if ($process) {
  Stop-Process -Id $targetPid -Force
  Write-Host "alpha HF test backend stopped (PID=$targetPid)"
} else {
  Write-Host "alpha HF test backend process $targetPid was not running."
}

Remove-Item $pidFile -ErrorAction SilentlyContinue
