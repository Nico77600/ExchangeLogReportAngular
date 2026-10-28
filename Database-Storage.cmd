@echo off
setlocal
set DOTNET_CLI_TELEMETRY_OPTOUT=1
if not exist "%~dp0host\ExchangeLogReportAngular.exe" (
  echo The portable host is missing. Extract the complete package.
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0tools\Test-PackageIntegrity.ps1" -Root "%~dp0."
if errorlevel 1 exit /b 1
if "%~1"=="" (
  echo Read-only audit:
  echo   Database-Storage.cmd --storage-audit --database "D:\Copy\ExchangeLogReport.sqlite"
  echo New compacted copy, without schema change:
  echo   Database-Storage.cmd --storage-copy --database "D:\Copy\ExchangeLogReport.sqlite" --destination "D:\Copy\Compacted.sqlite" --output "D:\Copy\Compacted.audit.json" --confirm-copy --vacuum
  echo New optimized copy for this Angular package only:
  echo   Database-Storage.cmd --storage-copy --database "D:\Copy\ExchangeLogReport.sqlite" --destination "D:\Copy\Optimized.sqlite" --output "D:\Copy\Optimized.audit.json" --confirm-copy --migrate --repack --vacuum
  echo Read README.txt before running maintenance. Original files are never replaced.
  exit /b 0
)
"%~dp0host\ExchangeLogReportAngular.exe" %*
exit /b %errorlevel%
