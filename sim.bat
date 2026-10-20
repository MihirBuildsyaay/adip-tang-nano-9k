@echo off
rem Usage:  sim.bat            run all testbenches
rem         sim.bat wave       run tb_wave and open GTKWave
rem         sim.bat pe|array|mult|top   run one testbench (pe/array open GTKWave)
rem         sim.bat top   also prints the A, B, C text the board will send over UART
rem Run from the OSS CAD Suite terminal (iverilog, vvp, gtkwave on PATH).
setlocal
cd /d "%~dp0"
if not exist sim\out mkdir sim\out

set RTL=rtl/multiplier_2bit.v rtl/reconfigurable_multiplier.v rtl/accumulator.v rtl/adip_pe.v rtl/systolic_array.v rtl/shared_shifter.v rtl/weight_memory.v rtl/input_memory.v rtl/output_memory.v rtl/adip_controller.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_cmd.v rtl/bin2bcd.v rtl/uart_report.v rtl/button_filter.v rtl/adip_top.v

if "%1"=="wave"  goto wave
if "%1"=="pe"    goto pe
if "%1"=="array" goto array
if "%1"=="mult"  goto mult
if "%1"=="top"   goto top

:all
call :do_mult  || exit /b 1
call :do_pe    || exit /b 1
call :do_array || exit /b 1
call :do_wave  || exit /b 1
call :do_top   || exit /b 1
echo.
echo === all testbenches finished - look for PASS/FAIL above ===
exit /b 0

:mult
call :do_mult
exit /b %errorlevel%
:pe
call :do_pe
start "" gtkwave sim\out\tb_pe.vcd
exit /b 0
:array
call :do_array
start "" gtkwave sim\out\tb_array.vcd
exit /b 0
:wave
call :do_wave
start "" gtkwave sim\out\tb_wave.vcd sim\tb_wave.gtkw
exit /b 0
:top
call :do_top
exit /b %errorlevel%

:do_mult
iverilog -g2005 -o sim/out/tb_multiplier.vvp tb/tb_multiplier.v rtl/multiplier_2bit.v rtl/reconfigurable_multiplier.v || exit /b 1
vvp sim/out/tb_multiplier.vvp
exit /b 0

:do_pe
iverilog -g2005 -o sim/out/tb_pe.vvp tb/tb_pe.v rtl/multiplier_2bit.v rtl/reconfigurable_multiplier.v rtl/accumulator.v rtl/adip_pe.v || exit /b 1
vvp sim/out/tb_pe.vvp
exit /b 0

:do_array
iverilog -g2005 -o sim/out/tb_array.vvp tb/tb_systolic_array.v rtl/multiplier_2bit.v rtl/reconfigurable_multiplier.v rtl/accumulator.v rtl/adip_pe.v rtl/systolic_array.v || exit /b 1
vvp sim/out/tb_array.vvp
exit /b 0

:do_wave
iverilog -g2005 -o sim/out/tb_wave.vvp tb/tb_wave.v %RTL% || exit /b 1
vvp sim/out/tb_wave.vvp
exit /b 0

:do_top
iverilog -g2005 -o sim/out/tb_top.vvp tb/tb_adip_top.v %RTL% || exit /b 1
vvp sim/out/tb_top.vvp
exit /b 0
