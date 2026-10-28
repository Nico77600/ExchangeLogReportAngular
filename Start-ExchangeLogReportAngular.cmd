@echo off
setlocal
set DOTNET_CLI_TELEMETRY_OPTOUT=1
set POWERSHELL_TELEMETRY_OPTOUT=1
if not exist "%~dp0powershell\pwsh.exe" (
  echo The portable PowerShell runtime is missing. Extract the complete package before starting it.
  pause
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0tools\Test-PackageIntegrity.ps1" -Root "%~dp0."
if errorlevel 1 exit /b 1
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0collector\Invoke-ExchangeLogReport.ps1" -Mode Serve %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
