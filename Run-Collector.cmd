@echo off
setlocal
set POWERSHELL_TELEMETRY_OPTOUT=1
rem Server garbage collector with 4 heaps not tied to processors: fewer, shorter collections while the collector parses and writes large batches.
set DOTNET_gcServer=1
set DOTNET_GCHeapCount=4
set DOTNET_GCNoAffinitize=1
if not exist "%~dp0powershell\pwsh.exe" (
  echo The bundled PowerShell runtime is missing. Extract the complete package.
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0tools\Test-PackageIntegrity.ps1" -Root "%~dp0."
if errorlevel 1 exit /b 1
if "%~1"=="" (
  "%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0collector\Invoke-ExchangeLogReport.ps1" -Mode Status
) else (
  "%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0collector\Invoke-ExchangeLogReport.ps1" %*
)
exit /b %errorlevel%
