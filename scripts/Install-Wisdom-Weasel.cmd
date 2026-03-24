@echo off
setlocal
set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"
set "SCRIPT=%~dp0scripts\Install-Wisdom-Weasel.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Install-Wisdom-Weasel.ps1"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
  echo.
  echo 安装失败，请查看 PowerShell 输出。
  pause
  exit /b 1
)
echo.
echo 安装完成。
pause
