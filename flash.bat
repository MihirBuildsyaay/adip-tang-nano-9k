@echo off
rem flash.bat         -> load into SRAM (lost at power-off, safe for development)
rem flash.bat flash   -> write to on-board flash (design starts at every power-up)
rem Needs the WinUSB driver on "Interface 0" (see README, Zadig step).
setlocal
cd /d "%~dp0"
if "%1"=="flash" (
    openFPGALoader -b tangnano9k -f build/adip.fs
) else (
    openFPGALoader -b tangnano9k build/adip.fs
)
