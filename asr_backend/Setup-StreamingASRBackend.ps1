$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonCmd = "py"
$pythonArgs = @("-3.13")
$venv = Join-Path $root ".venv"
$venvPython = Join-Path $venv "Scripts\python.exe"
$requirements = Join-Path $root "requirements.txt"
$downloadScript = Join-Path $root "download_model.py"

if (-not (Test-Path $venvPython)) {
    & $pythonCmd @pythonArgs -m venv $venv --system-site-packages
}

& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r $requirements
& $venvPython -m pip install torchaudio --index-url https://download.pytorch.org/whl/cpu
& $venvPython -m pip install funasr --no-deps
$env:HF_HUB_DISABLE_XET = "1"
& $venvPython $downloadScript

Write-Host "Streaming ASR backend setup complete."
