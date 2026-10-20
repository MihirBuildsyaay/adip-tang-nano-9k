@echo off
rem First-time helper: installs pyserial if missing, then opens the app without a console.
rem For everyday use double-click ADiP_App.vbs or the desktop shortcut instead.
cd /d "%~dp0"
python -c "import serial" 2>nul || (echo Installing pyserial... & python -m pip install pyserial)
wscript "%~dp0ADiP_App.vbs"
