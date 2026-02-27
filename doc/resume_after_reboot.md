# Resume After Reboot

Last update: 2026-02-27

## Current State
- Active phase: **Phase 4 (UART Screen/Input Bridge)**.
- Completed in Phase 4:
  - UART command protocol in RTL (`peek/poke/step/run/reset/state/kbd/romr/romw/halt`).
  - UART TB is green: `tools/run_uart_bridge_tb.ps1`.
  - Host UART client exists: `tools/hack_uart_client.py`.
  - Keyboard injection path (`CMD_KBD` -> KBD register path) is wired.
- Not completed in Phase 4:
  - Screen delta streaming over UART.
  - Integrated PC viewer with interactive key events.

## Fast Resume Checklist
1. Open repo root: `c:\Projects\nand-fpga`
2. Re-run key regressions:
   - `powershell -ExecutionPolicy Bypass -File tools/run_uart_bridge_tb.ps1`
   - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile sim_full`
   - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile fpga_fit`
3. Continue implementation from: **Phase 4 / "Stream screen updates over UART (delta mode first)"**.

## Visual Smoke Tests
- PC-only visual:
  - `powershell -ExecutionPolicy Bypass -File tools/run_rect_visual_demo.ps1 -Profile fpga_fit`
  - Result image: `build/rect_visual_demo/screen.pbm`
- FPGA UART visual (two terminals):
  - A: `python tools/hack_uart_client.py --port COM5 watch --words-per-row 8 --rows 8 --always-render`
  - B: `python tools/hack_uart_client.py --port COM5 poke 0x4000 0xFFFF`

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

## Notes
- Worktree is intentionally dirty (many modified/untracked files in this iteration). This is expected for current in-progress state.
