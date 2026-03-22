@echo off
setlocal
set "SCRIPT=%~dp0scripts\Install-Wisdom-Weasel.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Install-Wisdom-Weasel.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
  echo.
  echo 安装失败，请查看 PowerShell 输出。
  pause
  exit /b 1
)
echo.
echo 安装完成。
pause
