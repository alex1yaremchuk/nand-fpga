# Resume After Reboot

Last update: 2026-03-03

## Current State
- Active phase: **Phase 8 (Jack + OS bring-up)**.
- Completed in Phase 4:
  - UART command protocol in RTL (`peek/poke/step/run/reset/state/kbd/romr/romw/halt/scrdelta`).
  - UART TB is green: `tools/run_uart_bridge_tb.ps1`.
  - Host UART client exists: `tools/hack_uart_client.py`.
  - Keyboard injection path (`CMD_KBD` -> KBD register path) is wired.
  - Screen delta streaming command is implemented (`CMD_SCRDELTA`), including TB coverage.
  - Integrated single-port `viewer` mode with keyboard input and run/pause control.
- Completed in Phase 5:
  - One-command Rect live viewer workflow (`tools/run_rect_uart_viewer_demo.ps1`).
  - FPGA-vs-golden dump correlation script is green (`tools/compare_fpga_uart_against_golden.ps1`).
  - Keyboard interactive UART smoke is green (`tools/run_keyboard_uart_smoke.ps1`).
  - Strict debug-state parity hardening (`-StrictPcDump`) now checks `PC/A/D` without special-case variance bypass.
- Completed in Phase 6 / 6.5:
  - Viewer keyboard loop hardened (forced key-up edge + bounded key events per frame).
  - Viewer interaction options landed (`--hard-clear-per-frame`, tuned key timing args, periodic `kbd=0` heartbeat).
  - Keyboard soak + latency + protocol-diagnostic gates are wired into hardware smoke scripts.
  - Sequenced UART wrapper (`CMD_SEQ`) implemented in RTL with duplicate-request response cache.
  - Host `hack_uart_client.py` supports `--seq-mode auto|on|off` (default `auto` via `DIAG` capability probe).
- Completed in Phase 9 (partial):
  - Unified interactive CLI/TUI exists: `tools/hack_cli.py`.
  - CI core smoke workflow exists: `.github/workflows/core-smoke.yml`.
  - Daily regression bundle script exists: `tools/run_daily_regression_bundle.ps1` (pinned 4-case runtime subset gate + optional hardware gate).
  - BRAM-final regression bundle exists: `tools/run_bram_final_regression.ps1` (unit tests + pinned runtime subset sim/hw + project12 core strict with hard fpga-fit budget gate).
  - CLI presets wired: `bram_final`, `sim_only`, `fpga_fast`, `fpga_full` (`bram_final` is recommended for BRAM completion).
  - Latest BRAM-final hardware run passed on `COM7` (`build/bram_final_regression_check/summary.txt`).
- FPGA profile update:
  - `fpga_fit` ROM widened to `ROM_ADDR_W=14` (16K words / 32768 bytes) while keeping reduced screen (`128x64`).
  - Gowin synthesis + PnR completed successfully with this profile (`hack_computer/impl/pnr/hack_computer.rpt.txt`).
  - Hardware ROM probe with 9000-word image and `--rom-addr-w 14` now passes on `COM7` after reflashing.
- Completed in Phase 8 (incremental):
  - Runtime smoke scripts now support staged runtime selection: `-RuntimeMode stubs|hybrid|full`.
  - `run_jack_project12_api_smoke.ps1`: staged runtime with case-compatibility guards.
  - `run_jack_official_runtime_sim.ps1`: staged runtime with safe full-mode subset handling, plus `-Profile` and `-VmSyncWaits`.
  - OS source compile/run smoke added: `RuntimeMode=os_jack` + `CheckMode=compile`.
  - `run_jack_project12_api_smoke.ps1` now supports strict `RuntimeMode=os_jack` for project-12 API suite:
    - base: `ArrayTest`, `MemoryTest`, `MathTest`
    - optional: `StringTest` (`-IncludeStringTest`)
    - optional extended: `OutputTest`, `ScreenTest`, `SysTest`, `KeyboardTest` (`-IncludeExtendedTests`)
  - Reduced `fpga_fit` runtime subset defined and scripted:
    - sim: `tools/run_jack_official_runtime_fpga_subset_sim.ps1` (`Seven`, `ConvertToBin`, `Average`, `Square`, strict; default `VmSyncWaits=1`, `ConvertToBin` override `2`)
    - hardware: `tools/run_jack_official_runtime_fpga_subset_hw.ps1` (strict RAM/SCREEN checks, mode support `eq/ne/ge/gt/le/lt`)
    - `ComplexArrays` is kept optional and currently fails `fpga_fit` ROM16K budget (~24K words with stubs).
  - Wrapper entry points:
    - `tools/run_jack_project12_os_compile_smoke.ps1`
    - `tools/run_jack_project12_os_strict_smoke.ps1`
    - `tools/run_jack_official_runtime_os_compile_smoke.ps1`
  - `run_jack_project12_api_smoke.ps1` / `run_jack_project12_os_strict_smoke.ps1` support fpga-fit budget visibility:
    - `-ReportFpgaFitBudget`
    - `-FailOnFpgaFitBudget`
  - Global ROM-shrinking knobs added for project12 strict runs:
    - `-CompactStringLiterals`
    - `-VmSyncWaits N`
  - Latest shrink trial (`CompactStringLiterals + VmSyncWaits=1`) reduced ROM size notably for several cases
    (`ArrayTest/MemoryTest/MathTest/ScreenTest ~20.6-20.7%`, `OutputTest ~34.2%`, `SysTest ~37.4%`),
    but all extended `os_jack` cases still overflow `fpga_fit` ROM16K.
  - Additional optimization landed: per-case runtime class linking (`RuntimeClasses`) in `os_jack` mode.
    - Result: `ArrayTest`, `MemoryTest`, `MathTest` now pass strict + fpga-fit budget with ROM well below 16K.
    - Remaining overflow is now concentrated in String/Output/Screen/Sys/Keyboard extended cases.

## Pending Focus
- Phase 6:
  - Add automated long-session viewer soak (>=30 min) with pass/fail criteria and compact artifacts.
- Phase 8:
  - Keep ROM budget gates explicit during OS migration and re-evaluate `ComplexArrays`/`Pong` for `fpga_fit` if ROM budget increases.
- Phase 9:
  - Keep presets aligned with changing regression gates (`bram_final`, `sim_only`, `fpga_fast`, `fpga_full`).

## Fast Resume Checklist
1. Open repo root: `c:\Projects\nand-fpga`
2. Re-run key regressions:
   - `powershell -ExecutionPolicy Bypass -File tools/run_uart_bridge_tb.ps1`
   - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile sim_full`
   - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile fpga_fit`
3. On hardware, run strict golden compare:
   - `powershell -ExecutionPolicy Bypass -File tools/compare_fpga_uart_against_golden.ps1 -Port COM7 -Profile fpga_fit -StrictPcDump`
4. Capture/compare FPGA dumps vs golden:
   - `python tools/hack_uart_client.py --port COM7 diag --json` (`seq_capable=true` on new bitstream)
5. Interactive keyboard smoke:
   - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_interactive_demo.ps1 -Port COM7`
   - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_uart_smoke.ps1 -Port COM7`
6. Start/continue Phase 8 runtime track:
   - `powershell -ExecutionPolicy Bypass -File tools/run_bram_final_regression.ps1 -Fetch -Port COM7`
   - `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_strict_smoke.ps1 -Fetch -IncludeStringTest -IncludeExtendedTests -CompactStringLiterals -VmSyncWaits 1 -ReportFpgaFitBudget`
   - `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_strict_smoke.ps1 -Case ArrayTest,MemoryTest,MathTest -CompactStringLiterals -VmSyncWaits 1 -ReportFpgaFitBudget -FailOnFpgaFitBudget`
   - `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_fpga_subset_sim.ps1 -Fetch`
   - `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch -Port COM7 -Project12Extended -FailOnFpgaFitBudgetOverflow`
   - `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_compile_smoke.ps1 -Fetch`
   - `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_api_smoke.ps1 -Fetch -IncludeExtendedTests -RuntimeMode stubs`
7. Optional unified entry point:
   - `python tools/hack_cli.py`
8. Continue implementation from: **Phase 8 next concrete steps in README (ROM budget visibility + expand `fpga_fit` subset coverage)**.

## Visual Smoke Tests
- PC-only visual:
  - `powershell -ExecutionPolicy Bypass -File tools/run_rect_visual_demo.ps1 -Profile fpga_fit`
  - Result image: `build/rect_visual_demo/screen.pbm`
- FPGA UART visual (two terminals):
  - Single terminal: `python tools/hack_uart_client.py --port COM7 viewer --words-per-row 8 --rows 32 --auto-run`
  - Optional read-only monitor: `python tools/hack_uart_client.py --port COM7 watch --words-per-row 8 --rows 32 --always-render`
- Snake visual (interactive):
  - `powershell -ExecutionPolicy Bypass -File tools/run_snake_demo.ps1 -Port COM7`
  - In-game controls: `W/A/S/D` or arrows (viewer uses sticky input + non-delta mode for playability).

## Key Files Added/Changed For Current Progress
- Plan/status:
  - `README.md`
  - `.github/workflows/core-smoke.yml`
  - `doc/uart_bridge_protocol.md`
- UART RTL:
  - `hack_computer/src/io/uart_rx.v`
  - `hack_computer/src/io/uart_tx.v`
  - `hack_computer/src/io/uart_bridge.v`
- Top integration:
  - `hack_computer/src/app/top.v`
  - `hack_computer/src/app/project_config.vh`
  - `hack_computer/hack_computer.gprj`
- Testbenches/scripts:
  - `tb/uart_bridge_tb.v`
  - `tools/run_uart_bridge_tb.ps1`
  - `tools/hack_uart_client.py`
  - `tools/hack_cli.py`
  - `tools/compare_fpga_uart_against_golden.ps1`
  - `tools/run_keyboard_interactive_demo.ps1`
  - `tools/run_keyboard_uart_smoke.ps1`
  - `tools/run_keyboard_uart_soak.ps1`
  - `tools/run_keyboard_uart_latency.ps1`
  - `tools/run_rect_uart_viewer_demo.ps1`
  - `tools/run_snake_demo.ps1`
  - `tools/programs/SnakeLite.vm`
  - `tools/run_jack_project12_os_compile_smoke.ps1`
  - `tools/run_jack_project12_os_strict_smoke.ps1`
  - `tools/run_jack_official_runtime_os_compile_smoke.ps1`
  - `tools/run_jack_official_runtime_fpga_subset_sim.ps1`
  - `tools/run_jack_official_runtime_fpga_subset_hw.ps1`
  - `tools/run_daily_regression_bundle.ps1`
  - `tools/run_bram_final_regression.ps1`

## Notes
- Worktree is intentionally dirty (many modified/untracked files in this iteration). This is expected for current in-progress state.
