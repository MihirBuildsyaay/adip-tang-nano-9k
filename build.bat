@echo off
rem Synthesis + place&route + bitstream for Tang Nano 9K (open-source flow).
rem Run from the OSS CAD Suite terminal (yosys, nextpnr-himbaechel or nextpnr-gowin, gowin_pack on PATH).
setlocal
cd /d "%~dp0"
if not exist build mkdir build

set RTL=rtl/multiplier_2bit.v rtl/reconfigurable_multiplier.v rtl/accumulator.v rtl/adip_pe.v rtl/systolic_array.v rtl/shared_shifter.v rtl/weight_memory.v rtl/input_memory.v rtl/output_memory.v rtl/adip_controller.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_cmd.v rtl/bin2bcd.v rtl/uart_report.v rtl/button_filter.v rtl/adip_top.v

rem synth_gowin is split around its LUT-mapping step:
rem  * its default abc9 step crashes on Windows yosys builds (assert in write_xaiger2)
rem  * -noalu + plain 4-input LUT mapping is what makes the design fit the GW1NR-9
rem    (with ALU carry chains / wide LUTs it needs more than 100 %% of the LUTs)
set SYN=synth_gowin -top adip_top -noalu -run :map_luts; abc -lut 4; clean; synth_gowin -top adip_top -noalu -run map_cells: -json build/adip.json

echo [1/3] Yosys synthesis...
yosys -l build/yosys.log -p "read_verilog %RTL%; %SYN%" > nul
if errorlevel 1 ( echo Yosys FAILED - see build\yosys.log & exit /b 1 )

echo [2/3] nextpnr place and route...
where nextpnr-himbaechel >nul 2>&1
if errorlevel 1 (
    nextpnr-gowin --json build/adip.json --write build/adip_pnr.json --freq 27 --device GW1NR-LV9QN88PC6/I5 --family GW1N-9C --cst constraints/tang_nano9k.cst -l build/nextpnr.log > nul 2>&1
) else (
    nextpnr-himbaechel --json build/adip.json --write build/adip_pnr.json --freq 27 --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C --vopt cst=constraints/tang_nano9k.cst -l build/nextpnr.log > nul 2>&1
)
if errorlevel 1 ( echo nextpnr FAILED - see build\nextpnr.log & exit /b 1 )

echo [3/3] gowin_pack bitstream...
gowin_pack -d GW1N-9C -o build/adip.fs build/adip_pnr.json
if errorlevel 1 ( echo gowin_pack FAILED & exit /b 1 )

echo.
echo === Timing / utilisation (full details: build\nextpnr.log, build\yosys.log) ===
rem the last "Max frequency" line is the post-route value (earlier ones are estimates)
for /f "delims=" %%L in ('findstr /C:"Max frequency" build\nextpnr.log') do set FMAX=%%L
echo %FMAX%
findstr /C:"LUT4:" /C:" DFF:" /C:"IOB:" /C:"BSRAM:" build\nextpnr.log
echo.
echo Bitstream: build\adip.fs   -^>  now run flash.bat
