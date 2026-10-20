@echo off
rem Stops the ADiP board watcher and removes it from Windows startup.
cd /d "%~dp0"
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ADiP_board_watcher.bat" 2>nul
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ADiP_board_watcher.vbs" 2>nul
if exist "pc\.watcher.pid" (
  for /f %%i in (pc\.watcher.pid) do taskkill /PID %%i /F >nul 2>nul
  del "pc\.watcher.pid"
)
echo ADiP auto-start removed. You can still start the app with ADiP_App.vbs
pause
