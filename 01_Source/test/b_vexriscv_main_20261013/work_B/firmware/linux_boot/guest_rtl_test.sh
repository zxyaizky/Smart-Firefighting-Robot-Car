#!/bin/sh
set -eu
apk add --no-cache verilator verilator-dev
mkdir -p /build/cpu_sim
cd /build/cpu_sim
wget -q -O rtl.tar.gz http://10.0.2.2:18990/cache/cpu_rtl_test.tar.gz
tar -xzf rtl.tar.gz
verilator --binary --timing -j 4 --top-module tb_linux -Wno-fatal -O3 \
    --x-initial unique --x-assign unique \
    VexRiscv_Linux.v vexriscv_linux_top.v vexriscv_b_memory.v vexriscv_b_boot_rom.v \
    cpu_uart.v linux_timer.v us100_uart_rx.v tb_linux.v >/build/out/verilator_build.log 2>&1
: >/build/out/verilator.log
for seed in 1 23; do
    echo "TEST_SEED=$seed" >>/build/out/verilator.log
    obj_dir/Vtb_linux +verilator+rand+reset+2 +verilator+seed+$seed >>/build/out/verilator.log 2>&1
done
python3 /inputs/send_test_logs.py
