@echo off
setlocal

rem ---------------------------------------------------------------
rem  Verbal Outlet - build a standalone app
rem  Double-click this file to build a fast release copy of the app
rem  and open its folder. You can copy that folder anywhere.
rem ---------------------------------------------------------------

cd /d "%~dp0"

set "FLUTTER_BIN=%LOCALAPPDATA%\flutter_sdk\flutter\bin"
if exist "%FLUTTER_BIN%\flutter.bat" set "PATH=%FLUTTER_BIN%;%PATH%"

where flutter >nul 2>nul
if errorlevel 1 (
  echo.
  echo   Flutter could not be found.
  echo   Expected it here:
  echo     %FLUTTER_BIN%\flutter.bat
  echo.
  pause
  exit /b 1
)

echo.
echo   Building the release app. This takes a minute or two...
echo.

flutter build windows --release
if errorlevel 1 (
  echo.
  echo   The build failed. Scroll up to see why.
  echo.
  pause
  exit /b 1
)

echo.
echo   Done. Opening the folder - run verbal_outlet.exe inside it.
echo.
start "" "%~dp0build\windows\x64\runner\Release"
pause
