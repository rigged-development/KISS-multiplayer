@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build-all.ps1"
if errorlevel 1 (
  echo.
  echo Build fehlgeschlagen. Details siehe Ausgabe oben.
  pause
  exit /b 1
)
echo.
echo Build erfolgreich.
endlocal

