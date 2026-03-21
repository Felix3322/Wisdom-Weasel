param(
  [string]$ModelId = 'Qwen/Qwen3-0.6B'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = (Resolve-Path (Join-Path $root '..')).Path
$pidFile = Join-Path $root '.alpha_hf_test_backend.pid'
$logsDir = Join-Path $root 'logs'

if (Test-Path $pidFile) {
  $existingPid = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($existingPid) {
    $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
    if ($existingProcess) {
      Write-Host "alpha HF test backend is already running (PID=$existingPid)"
      exit 0
    }
  }
  Remove-Item $pidFile -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$stdoutPath = Join-Path $logsDir 'alpha_hf_test.stdout.log'
$stderrPath = Join-Path $logsDir 'alpha_hf_test.stderr.log'
$pythonExe = Join-Path $workspaceRoot 'hf_backend\.venv\Scripts\python.exe'
$serverScript = Join-Path $workspaceRoot 'alpha_backend\hf_test_rerank_server.py'

$env:ALPHA_TEST_MODEL = $ModelId
$env:PYTHONUTF8 = '1'

$process = Start-Process `
  -FilePath $pythonExe `
  -ArgumentList @('-u', $serverScript) `
  -WorkingDirectory $workspaceRoot `
  -RedirectStandardOutput $stdoutPath `
  -RedirectStandardError $stderrPath `
  -PassThru

$process.Id | Set-Content $pidFile
Write-Host "alpha HF test backend started (PID=$($process.Id))"
Write-Host "model: $ModelId"
Write-Host "stdout: $stdoutPath"
Write-Host "stderr: $stderrPath"
