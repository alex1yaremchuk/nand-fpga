# Golden Update Policy (`tools/baseline_golden`)

This policy defines when `tools/baseline_golden` may be regenerated.

## Allowed Reasons
- Intentional architectural/timing/protocol change that affects expected dumps.
- Intentional test-scope expansion (new baseline case added).
- Bug fix that changes functional behavior and is validated end-to-end.

## Required Evidence
- Simulation parity:
  - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile sim_full`
  - `powershell -ExecutionPolicy Bypass -File tools/compare_baseline_against_golden.ps1 -Profile fpga_fit`
- Hardware parity (when change affects UART/CPU/memory execution path):
  - `powershell -ExecutionPolicy Bypass -File tools/compare_fpga_uart_against_golden.ps1 -Port COM7 -Profile fpga_fit`
- Toolchain parity (when assembler/VM path changed):
  - `powershell -ExecutionPolicy Bypass -File tools/run_hack_asm_tests.ps1`
  - `powershell -ExecutionPolicy Bypass -File tools/run_hack_vm_tests.ps1`

## Review Rules
- Golden updates must be in a dedicated PR or clearly isolated commit section.
- PR description must include:
  - exact reason for update,
  - commands executed,
  - before/after impact summary (which tests/cases changed and why).
- No golden update is accepted if the reason is only "to make tests pass".

## Non-goals
- This policy does not relax ROM/RAM/SCREEN budget gates.
- This policy does not replace root-cause analysis of regressions.
