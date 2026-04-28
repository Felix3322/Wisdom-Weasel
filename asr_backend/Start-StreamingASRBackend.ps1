$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$python = Join-Path $root ".venv\Scripts\python.exe"
$logDir = Join-Path $root "logs"
$logFile = Join-Path $logDir "asr_backend.log"
$errFile = Join-Path $logDir "asr_backend.err.log"

if (-not (Test-Path $python)) {
    throw "Python 虚拟环境不存在：$python"
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -eq "python.exe" -and
        $_.CommandLine -like "*uvicorn app.main:app*" -and
        $_.CommandLine -like "*8013*"
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

$env:HF_HOME = Join-Path $env:LOCALAPPDATA "huggingface"
$env:HF_HUB_DISABLE_XET = "1"
$env:WW_ASR_MODEL_DIR = Join-Path $root "models\paraformer-zh-streaming"

Start-Process `
    -FilePath $python `
    -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "8013") `
    -WorkingDirectory $root `
    -RedirectStandardOutput $logFile `
    -RedirectStandardError $errFile `
    -WindowStyle Hidden | Out-Null

Write-Host "Streaming ASR backend started. Logs: $logFile"
