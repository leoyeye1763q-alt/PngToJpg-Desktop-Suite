@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0PngToJpgLauncher.exe" (
    start "" "%~dp0PngToJpgLauncher.exe" %*
    exit /b 0
)
set "PWSH=pwsh.exe"
where "%PWSH%" >nul 2>&1 || (
    echo PowerShell 7 ^(pwsh.exe^) was not found. Install it and try again.
    pause
    exit /b 1
)
start "PNG to JPG" "%PWSH%" -NoLogo -NoProfile -File "%~dp0PngToJpg.ps1" %*
endlocal
