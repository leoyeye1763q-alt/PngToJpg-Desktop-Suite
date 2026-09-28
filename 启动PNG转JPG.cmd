@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0PngToJpgLauncher.exe" (
    start "" "%~dp0PngToJpgLauncher.exe" %*
    exit /b 0
)
set "PWSH=C:\Users\Super-pc998\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh.exe"
start "PNG to JPG" "%PWSH%" -NoLogo -NoProfile -File "%~dp0PngToJpg.ps1" %*
endlocal
