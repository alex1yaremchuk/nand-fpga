# Resume After Reboot

Last update: 2026-02-27

## Current State
- Active phase: **Phase 5 (Hardware End-to-End)**.
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
- Pending in Phase 5:
  - Optional strict debug-state parity hardening (`-StrictPcDump`).

## Fast Resume Checklist
1. Open repo root: `c:\Projects\nand-fpga`
2. Re-run key regressions:
   - `powershell -ExecutionPolicy Bypass -File tools/run_uart_bridge_tb.ps1`
   - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile sim_full`
   - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile fpga_fit`
3. On hardware, run one-port interactive viewer:
   - `python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 8 --auto-run`
4. Capture/compare FPGA dumps vs golden:
   - `powershell -ExecutionPolicy Bypass -File tools/compare_fpga_uart_against_golden.ps1 -Port COM5 -Profile fpga_fit`
5. Interactive keyboard smoke:
   - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_interactive_demo.ps1 -Port COM5`
   - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_uart_smoke.ps1 -Port COM5`
6. Rect live viewer demo:
   - `powershell -ExecutionPolicy Bypass -File tools/run_rect_uart_viewer_demo.ps1 -Port COM5`
7. Continue implementation from: **Phase 5 / optional strict debug-state parity hardening (`A/D`)**.

## Visual Smoke Tests
- PC-only visual:
  - `powershell -ExecutionPolicy Bypass -File tools/run_rect_visual_demo.ps1 -Profile fpga_fit`
  - Result image: `build/rect_visual_demo/screen.pbm`
- FPGA UART visual (two terminals):
  - Single terminal: `python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 8 --auto-run`
  - Optional read-only monitor: `python tools/hack_uart_client.py --port COM5 watch --words-per-row 8 --rows 8 --always-render`

## Key Files Added/Changed For Current Progress
- Plan/status:
  - `README.md`
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
  - `tools/compare_fpga_uart_against_golden.ps1`
  - `tools/run_keyboard_interactive_demo.ps1`
  - `tools/run_keyboard_uart_smoke.ps1`
  - `tools/run_rect_uart_viewer_demo.ps1`

## Notes
- Worktree is intentionally dirty (many modified/untracked files in this iteration). This is expected for current in-progress state.
