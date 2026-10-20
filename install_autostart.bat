@echo off
rem Makes the ADiP app open by itself whenever the Tang Nano 9K is plugged in.
rem Run once (double-click). Undo with uninstall_autostart.bat
setlocal
cd /d "%~dp0"
python -c "import serial" 2>nul || (echo Installing pyserial... & python -m pip install pyserial)
set "PYW="
for /f "delims=" %%P in ('python "%~dp0pc\find_pythonw.py"') do set "PYW=%%P"
if not exist "%PYW%" (
  echo pythonw.exe not found. Install Python from python.org and tick "Add python.exe to PATH".
  pause
  exit /b 1
)
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
del "%STARTUP%\ADiP_board_watcher.bat" 2>nul
set "LINK=%STARTUP%\ADiP_board_watcher.vbs"
echo CreateObject("WScript.Shell").Run """%PYW%"" ""%~dp0pc\adip_watcher.pyw""", 0, False> "%LINK%"
cscript //nologo "%~dp0pc\make_shortcut.vbs"
start "" "%PYW%" "%~dp0pc\adip_watcher.pyw"
echo.
echo Done. From now on the ADiP app opens automatically when you plug in the board
echo (also after restarting Windows). Remove it with uninstall_autostart.bat
pause
