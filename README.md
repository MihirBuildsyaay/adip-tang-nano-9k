# ADiP-inspired Adaptive-Precision Systolic Array - Tang Nano 9K
Open-source flow: VS Code -> Icarus Verilog -> GTKWave -> Yosys/nextpnr -> openFPGALoader (Zadig driver) -> serial terminal.

## 1. Tools (one-time)
- Install **OSS CAD Suite** (YosysHQ, Windows build). It contains iverilog, vvp, gtkwave, yosys, nextpnr-gowin, gowin_pack and openFPGALoader. Open its terminal (`start.bat`) and `cd` into this folder - or start VS Code from that terminal (`code .`) so the tools are on PATH.
- VS Code: Verilog-HDL/SystemVerilog extension (mshr-h). `.vscode/settings.json` already sets iverilog as linter. `Terminal > Run Task` has Simulate / Waveform / Build / Program.

## 2. Zadig driver (one-time)
1. Plug in the Tang Nano 9K. 2. Zadig > Options > **List All Devices**.
3. Pick the **Interface 0** entry of the board (the JTAG one), choose **WinUSB** (libusbK also works) > Replace Driver.
4. **Do not touch Interface 1** - it is the USB-UART and must stay a COM port.
5. Test: `openFPGALoader --detect -b tangnano9k` should find the GW1NR-9.
(The Gowin Programmer will no longer see the board after this; reinstall the original driver if you go back to it.)

## 3. Simulate (`sim.bat`)
- `sim.bat` - all testbenches (look for PASS/FAIL)
- `sim.bat wave` - fast all-modes check, opens `sim\out\tb_wave.vcd` in GTKWave
- `sim.bat pe` / `sim.bat array` - unit tests with waveforms
- Full UART test with waves: `vvp sim/out/tb_top.vvp +dump` then open `sim\out\tb_top.vcd`
GTKWave signals to add: `dut.u_ctrl.state`, `dut.u_ctrl.cnt`, `dut.mode_q`, `dut.u_arr...`, `dut.busy`, `dut.done`.

## 4. Build and program
- `build.bat` -> yosys + nextpnr (himbaechel, or nextpnr-gowin if that is all you have) + gowin_pack, produces `build\adip.fs`; prints post-route Fmax and utilisation (logs in `build\`).
- Synthesis runs `synth_gowin -noalu` with plain 4-input LUT mapping (`abc -lut 4`) instead of the default abc9 step: abc9 crashes on the Windows yosys build (assert in `write_xaiger2`), and the default ALU/wide-LUT mapping needs ~104 % of the LUTs.
- Result (N = 4, OSS CAD Suite yosys 0.69, 27 MHz constraint):

  | Design | LUT4 | FF | Fmax (post-route) |
  |---|---|---|---|
  | unsigned only (before INT8) | 6064 / 8640 (70 %) | 1960 / 6480 (30 %) | 59.4 MHz |
  | **current: unsigned + signed INT8** | 8230 / 8640 (95 %) | 2059 / 6480 (31 %) | 69.6 MHz |

  The device is nearly full - N = 8 does not fit the GW1NR-9.
- `flash.bat` -> load to SRAM (use during development). `flash.bat flash` -> write to flash (starts at every power-up).
- Equivalent commands are inside `build.bat` (device `GW1NR-LV9QN88PC6/I5`, family `GW1N-9C`).
- If your nextpnr build has no `nextpnr-gowin`, use `nextpnr-himbaechel ... --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C --vopt cst=constraints/tang_nano9k.cst`.

## 5. Use on the board
- Serial terminal (PuTTY / your terminal): the COM port of Interface 1, **115200, 8N1**.
- Button on pin 4 = start, pin 3 = mode (swap the two numbers in the .cst if they feel reversed). Also auto-runs once at power-up.
- LED0 DONE, LED1 BUSY, LED2 8x8, LED3 8x4, LED4 8x2, LED5 UART printing.

Expected output (default data, 8x8) - A, B and C are all printed in decimal:
```
ADiP MODE=8x8
A matrix:
  1   2   3   4
  5   6   7   8
  9  10  11  12
 13  14  15  16

B matrix (8-bit):
 41 114 187   4
 77 150 223  40
113 186   3  76
149 222  39 112

C = A x B:
  1130   1860    798    760
  2650   4548   2606   1688
  4170   7236   4414   2616
  5690   9924   6222   3544

LAT=0x01C cycles
DONE
```
Other modes: `python3 sim/golden_model.py 4` (signed: `python3 sim/golden_model.py 4 signed`). In 8x4 / 8x2 mode B is shown as the 4-bit / 2-bit weights (4x8 / 4x16) and C has 8 / 16 columns.

### Signed INT8
Send `I` over UART (or tick **Signed (INT8)** in the app) to switch to signed arithmetic, `U` to go back (power-up default is unsigned).
A is then INT8 (-128..127) and B is INT8 / INT4 (-8..7) / INT2 (-2..1) two's complement, from the same packed bytes.
The header becomes `ADiP MODE=8x8 SIGNED` and every column is one character wider for the `-`:
```
B matrix (8-bit):
  41  114  -69    4
...
C = A x B:
    106    -444      30     760
```
How: each 2-bit chunk multiplier takes a "signed chunk" flag (top chunk of A, top chunk of every weight of the current mode), lane sums, accumulators and results are two's complement (one bit wider).

## 6. Laptop app - choose mode, type A and B, see the result in its own window
Files: `pc/adip_gui.py` (window), `pc/adip_core.py` (protocol + checks), `run_gui.bat`.
1. Use normal Windows Python from python.org (has tkinter), **not** the OSS CAD Suite python.
2. First time: double-click `run_gui.bat` (installs `pyserial`). After that double-click **`ADiP_App.vbs`** or the desktop shortcut **ADiP Matrix Accelerator** - only the app window opens, no black command window.
3. Pick the board's COM port (USB-UART, Interface 1) > Connect. Close PuTTY/other terminals first - only one program can use the port.
4. Choose 8b x 8b / 8b x 4b / 8b x 2b, type A (0-255) and B (0-255 / 0-15 / 0-3; B gets 4 / 8 / 16 columns), press **Run on FPGA**.
   Tick **Signed (INT8)** for signed values: A -128..127, B -128..127 / -8..7 / -2..1.
5. The **ADiP Result** window shows C, latency, throughput (multiply-adds per cycle, MMAC/s and MOPS at 27 MHz), and a green check if every value equals the PC calculation (red cells if not). "Save as CSV" stores A, B, C plus latency and throughput.
- Tick **Demo mode** to try the app without the board.

### Animation: how the FPGA calculates it, cycle by cycle
**Animate: how it is calculated** (main window) animates the numbers you typed. **▶ Animate this calculation** (result window) animates the run the board just did and checks the end result against the FPGA's answer. In tiling mode you pick which block run to watch.
- The animation follows `adip_core.cycle_trace()`, a Python copy of the RTL dataflow:
  - **LOAD:** 16 cycles. One stationary weight byte per cycle goes into PE(r, c).
  - **COMPUTE:** 11 cycles. Row r of the array gets A[cnt-r][r] (the skew). Activations move one PE right per clock and partial sums move one PE down. The shared shifter under each column combines the lanes when a row of C leaves the array.
  - **STORE:** 1 cycle. 28 cycles in total, the same LAT the board reports.
- Colours mark rows of A and C. Click a PE to see inside it: x and w split into 2-bit chunks (signed top chunks are marked), the 16 two-bit multiplier products, the 4 lane sums, the shift-and-add and the partial sum passed down.
- Controls: Play/Pause (space), Next/Back (arrow keys), Reset, End, speed slider and fast weight loading.
- The self-test of `pc/adip_core.py` checks that every PE's chunk math equals a x w, and that the final C equals A x B.

### Bigger matrices: 8 x 8 and 16 x 16 by tiling (no FPGA change)
The array stays 4 x 4. Pick **Matrix size 8 x 8 (tiling)** or **16 x 16 (tiling)** and an orange *TILING MODE* banner appears; A and B are entered in two tabs, with every other 4 x 4 block shaded.
- A is cut into 4 x 4 tiles and B into 4 x 4 / 4 x 8 / 4 x 16 tiles (8x8 / 8x4 / 8x2 mode). Each tile pair is one normal FPGA run (same `U/I M A W S` commands).
- The FPGA does every multiply-add inside a tile. The PC adds the size/4 partial tiles along K and places the C tiles.
- FPGA runs for 16 x 16: **64** (8b x 8b), **32** (8b x 4b), **16** (8b x 2b). For 8 x 8: 8 / 4 / 4 (the last B tile of 8x2 is zero-padded). Lower precision means fewer runs, which is the ADiP benefit.
- The result window shows the runs, the total FPGA cycles (runs x 28), array-only throughput and the total time including USB. The 115200-baud UART link, not the array, sets the total time.
- The logic is in `pc/adip_core.py` (`tile_plan`, `tile_operands`, `add_tile`) and is checked by its self-test.

### Open the app automatically when the board is plugged in
1. Double-click `install_autostart.bat` once. It starts an invisible helper (`pc/adip_watcher.pyw`) now and at every Windows login (no console window), and puts an **ADiP Matrix Accelerator** shortcut on the desktop.
2. Plug in the board -> the app opens, finds the board and connects by itself ("Board found: COMx").
   If the app is already open it just comes to the front.
3. First time only: if the app does not pop up, start it with `run_gui.bat`, pick the port, Connect, press Run once.
   The app then remembers the board's USB ID (`pc/board_id.json`) and auto-start works from then on.
4. Remove with `uninstall_autostart.bat`.

### UART command protocol (PC -> FPGA, 115200 8N1, pin 18)
| Bytes | Meaning |
|---|---|
| `M` m | mode m = 0 (8x8), 1 (8x4), 2 (8x2) |
| `0` `1` `2` | same, typable in a terminal |
| `I` / `U` | signed INT8 / unsigned arithmetic (default unsigned) |
| `A` + 16 bytes | matrix A, row-major |
| `W` + 16 bytes | packed weights, row-major: 8x8 = B, 8x4 = B[r][2c] + 16*B[r][2c+1], 8x2 = 2-bit fields B[r][4c+k] << 2k |
| `S` | start; FPGA answers with the A/B/C text report |
An unfinished command is dropped after ~50 ms without bytes. Buttons still work as before.

## Notes
- Verified with Icarus Verilog (all testbenches PASS, unsigned and signed) and built with yosys / nextpnr-himbaechel / gowin_pack; dataflow and expected numbers also checked with `sim/golden_model.py` (N=4 and N=8, unsigned and signed).
- Weight-stationary skewed array (not ADiP's diagonal interconnect); unsigned or signed INT8 arithmetic; N must be a power of two.
- Take LUT/FF/Fmax numbers for the report from `build\nextpnr.log` / `build\yosys.log`, not from the ADiP paper.
- Linux/macOS: same commands; `sim/run_sim.sh` still works.
