#!/bin/sh
# Run all testbenches with Icarus Verilog:  sh sim/run_sim.sh
set -e
cd "$(dirname "$0")/.."
R=rtl
mkdir -p sim/out
iverilog -g2005 -o sim/out/tb_multiplier.vvp tb/tb_multiplier.v $R/multiplier_2bit.v $R/reconfigurable_multiplier.v
iverilog -g2005 -o sim/out/tb_pe.vvp tb/tb_pe.v $R/multiplier_2bit.v $R/reconfigurable_multiplier.v $R/accumulator.v $R/adip_pe.v
iverilog -g2005 -o sim/out/tb_array.vvp tb/tb_systolic_array.v $R/multiplier_2bit.v $R/reconfigurable_multiplier.v $R/accumulator.v $R/adip_pe.v $R/systolic_array.v
iverilog -g2005 -o sim/out/tb_top.vvp tb/tb_adip_top.v $R/multiplier_2bit.v $R/reconfigurable_multiplier.v $R/accumulator.v $R/adip_pe.v $R/systolic_array.v $R/shared_shifter.v $R/weight_memory.v $R/input_memory.v $R/output_memory.v $R/adip_controller.v $R/uart_tx.v $R/uart_rx.v $R/uart_cmd.v $R/bin2bcd.v $R/uart_report.v $R/button_filter.v $R/adip_top.v
for t in tb_multiplier tb_pe tb_array tb_top; do vvp sim/out/$t.vvp; done
