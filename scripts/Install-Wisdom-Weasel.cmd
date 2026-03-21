@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Wisdom-Weasel.ps1"
if errorlevel 1 (
  echo.
  echo 安装失败，请查看 PowerShell 输出。
  pause
  exit /b 1
)
echo.
echo 安装完成。
pause
