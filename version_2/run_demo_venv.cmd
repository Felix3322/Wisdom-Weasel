@echo off
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
  echo [ERROR] .venv\Scripts\python.exe not found
  pause
  exit /b 1
)

echo Project root: %cd%
echo Starting demo with venv Python...
".venv\Scripts\python.exe" -u ".\html_demo\main.py"

endlocal
