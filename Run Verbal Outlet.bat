@echo off
setlocal

rem ---------------------------------------------------------------
rem  Verbal Outlet - one-click launcher
rem  Double-click this file to build and run the app on Windows.
rem ---------------------------------------------------------------

cd /d "%~dp0"

rem Flutter lives outside the normal Windows install location.
set "FLUTTER_BIN=%LOCALAPPDATA%\flutter_sdk\flutter\bin"
if exist "%FLUTTER_BIN%\flutter.bat" set "PATH=%FLUTTER_BIN%;%PATH%"

where flutter >nul 2>nul
if errorlevel 1 (
  echo.
  echo   Flutter could not be found.
  echo.
  echo   Expected it here:
  echo     %FLUTTER_BIN%\flutter.bat
  echo.
  echo   If you moved Flutter, edit the FLUTTER_BIN line in this file.
  echo.
  pause
  exit /b 1
)

echo.
echo   Starting Verbal Outlet...
echo.
echo   Keep this window open while the app runs.
echo     r  = reload after a code change
echo     q  = quit
echo.

flutter run -d windows

echo.
echo   The app has stopped.
pause
