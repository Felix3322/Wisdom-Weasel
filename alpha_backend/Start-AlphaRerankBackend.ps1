$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root '.alpha_backend.pid'
$configPath = Join-Path $root 'config.toml'
$exampleConfigPath = Join-Path $root 'config.example.toml'
$exePath = Join-Path $root 'target\release\alpha-rerank-server.exe'
$logsDir = Join-Path $root 'logs'

if (Test-Path $pidFile) {
  $existingPid = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($existingPid) {
    $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
    if ($existingProcess) {
      Write-Host "alpha rerank backend is already running (PID=$existingPid)"
      exit 0
    }
  }
  Remove-Item $pidFile -ErrorAction SilentlyContinue
}

if (!(Test-Path $configPath)) {
  Copy-Item $exampleConfigPath $configPath
  Write-Host "Created config.toml from config.example.toml"
  Write-Host "Please edit $configPath and set your ONNX/tokenizer/LMDB paths, then rerun."
  exit 1
}

if (!(Test-Path $exePath)) {
  Write-Host "alpha rerank backend executable not found: $exePath"
  Write-Host 'Please build it first with: cargo build --release --manifest-path alpha_backend/Cargo.toml'
  exit 1
}

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$stdoutPath = Join-Path $logsDir 'alpha_backend.stdout.log'
$stderrPath = Join-Path $logsDir 'alpha_backend.stderr.log'

$process = Start-Process `
  -FilePath $exePath `
  -ArgumentList @('--config', $configPath, '--bind', '127.0.0.1:8011') `
  -WorkingDirectory $root `
  -RedirectStandardOutput $stdoutPath `
  -RedirectStandardError $stderrPath `
  -PassThru

$process.Id | Set-Content $pidFile
Write-Host "alpha rerank backend started (PID=$($process.Id))"
Write-Host "stdout: $stdoutPath"
Write-Host "stderr: $stderrPath"
