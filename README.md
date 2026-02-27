# hack-fpga (Tang Nano 20K)

Goal: implement nand2tetris Hack computer on Tang Nano 20K (Gowin GW2AR-18).

Quick resume: `doc/resume_after_reboot.md`

## Status
- [ ] Toolchain installed
- [ ] JTAG programming works
- [ ] UART monitor works
- [ ] ALU on hardware
- [ ] CPU on hardware

## Execution Plan
Track: keep one RTL codebase with two memory profiles.

### Phase 1: Profiles and Memory Baseline
- [x] Add `fpga_fit` profile (reduced ROM, configurable screen size).
- [x] Add `sim_full` profile (ROM32K + RAM16K + SCREEN8K) for PC RTL simulation.
- [x] Centralize profile knobs in `hack_computer/src/app/project_config.vh`.
- [x] Guard ROM against address wrap for reduced ROM profiles.
- [x] Add host-side ROM size checker (`tools/check_hack_rom_size.ps1`).

Quick check command:
- `powershell -ExecutionPolicy Bypass -File tools/check_hack_rom_size.ps1 -HackFile path/to/program.hack -Profile fpga_fit`

### Phase 2: Computer Core Stability
- [x] Document CPU+memory timing contract (`doc/cpu_memory_timing.md`).
- [x] Add dedicated CPU+memory timing testbench (`tb/cpu_memory_timing_tb.v`).
- [x] Run CPU testbenches locally with Icarus (`PASS`).
- [ ] Add CI wiring and persist test artifacts.
- [x] Add continuous `run` mode in addition to `step` (CPU page).
- [x] Add deterministic reset/boot testbench (`tb/cpu_core_reset_boot_tb.v`).

CPU testbench command:
- `powershell -ExecutionPolicy Bypass -File tools/run_cpu_core_tb.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_cpu_memory_timing_tb.ps1`

### Phase 3: Test Infrastructure
- [x] Build local test runner: load `.hack`, run N cycles, dump RAM/SCREEN/PC.
- [x] Add baseline tests (`Add`, `Max`, `Rect`) in `sim_full` (adapted for sync memory timing).
- [x] Add adapted tests for `fpga_fit` (same set, profile-aware runner).
- [x] Add compare artifacts (`golden` dumps) and profile checks.

Hack runner commands:
- `powershell -ExecutionPolicy Bypass -File tools/run_hack_runner.ps1 -HackFile path/to/program.hack -Profile sim_full -Cycles 20000`
- `powershell -ExecutionPolicy Bypass -File tools/run_hack_runner_smoke.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_baseline_program_tests.ps1 -Profile sim_full`
- `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile sim_full`
- `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile fpga_fit`
- `powershell -ExecutionPolicy Bypass -File tools/run_rect_visual_demo.ps1 -Profile fpga_fit`

### Phase 4: UART Screen/Input Bridge
- [x] Implement UART command protocol (`peek`, `poke`, `run`, `step`, `reset`).
- [x] Stream screen updates over UART (delta mode first, `SCRDELTA`).
- [x] Feed keyboard events from host into KBD register (`0x6000`).
- [x] Ship a small PC viewer tool (render screen + send key events).

UART bridge commands:
- `powershell -ExecutionPolicy Bypass -File tools/run_uart_bridge_tb.ps1`
- `python tools/hack_uart_client.py --port COM5 state`
- `python tools/hack_uart_client.py --port COM5 peek 0x0002`
- `python tools/hack_uart_client.py --port COM5 poke 0x0002 0x1234`
- `python tools/hack_uart_client.py --port COM5 scrdelta --sync`
- `python tools/hack_uart_client.py --port COM5 scrdelta --max-entries 12`
- `python tools/hack_uart_client.py --port COM5 watch --words-per-row 8 --rows 8 --interval 0.2`
- `python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 8 --auto-run`
- `python tools/hack_uart_client.py --port COM5 runhack --hack-file build/rect_visual_demo/Rect.hack --cycles 40 --rom-addr-w 13 --ram-base 0 --ram-words 1 --screen-words 5 --clear-screen-words 5 --out-dir build/fpga_uart_rect`
  - If your terminal flickers/artifacts, add `--interval 0.15` or `--no-clear`.

Quick visual checks:
1. PC-only (`sim_full`/`fpga_fit`, no FPGA):
   - `powershell -ExecutionPolicy Bypass -File tools/run_rect_visual_demo.ps1 -Profile fpga_fit`
   - See ASCII preview in terminal and image `build/rect_visual_demo/screen.pbm`.
2. UART on FPGA:
   - Single terminal: `python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 8 --auto-run`
   - Controls: `q` quit, `space` run/pause, `r` reset, `s` state, `x` key up.
   - `watch` still exists, but it is read-only and cannot share port with a second client.

### Phase 5: Hardware End-to-End
- [x] Run `Rect` on FPGA via UART viewer and verify rendering workflow (one-command script).
- [x] Run an interactive keyboard-driven program via UART.
- [x] Correlate FPGA dumps vs simulation dumps for same programs.

Hardware correlation command:
- `powershell -ExecutionPolicy Bypass -File tools/compare_fpga_uart_against_golden.ps1 -Port COM5 -Profile fpga_fit`
- Add `-StrictPcDump` to also require `D` and `A` register match in `pc_dump.txt` (default compares only `PC`).
- Hardware compare enables ROM write verification/retry to avoid UART programming glitches.

Interactive keyboard demo (single command):
- `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_interactive_demo.ps1 -Port COM5`
- Program: `tools/programs/KeyboardScreen.asm` (`KBD` controls `SCREEN[0]`, key code mirrored to `RAM[0]`).
- Automated smoke check:
  - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_uart_smoke.ps1 -Port COM5`

Rect live viewer demo (single command):
- `powershell -ExecutionPolicy Bypass -File tools/run_rect_uart_viewer_demo.ps1 -Port COM5`

## Project Layout
- `hack_computer/src/app`: top-level integration (`top.v`) and global config.
- `hack_computer/src/core`: core compute blocks (ALU, later CPU blocks).
- `hack_computer/src/io`: TM1638 and input conditioning.
- `hack_computer/src/mem`: memory modules (in progress).
- `hack_computer/src/constraints`: board pin constraints.
