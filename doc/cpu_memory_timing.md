# CPU/Memory Timing Contract

This document defines the current timing behavior used by the Hack FPGA implementation.

## Clocking Model
- Single synchronous domain (`Clock`).
- CPU state (`A`, `D`, `PC`) updates on `posedge Clock`.
- `reset` has priority over `step`.

## CPU Step Semantics
- On cycles where `step=1`, one instruction is executed.
- On cycles where `step=0`, CPU state holds.
- In `top.v`, effective CPU step is:
  - one-shot `cpu_step_req` (manual step), or
  - continuous `cpu_run` while `PAGE_CPU` is active.

## ROM Read Contract
- Instruction memory is BRAM-backed (`rom32k_prog` + `ram_bram`).
- BRAM read path is synchronous (`q <= mem[addr]` in `ram_bram`).
- For reduced ROM profiles (`ROM_ADDR_W < 15`):
  - writes outside configured ROM range are ignored,
  - reads outside configured ROM range return zero.
- Host-side size guard: `tools/check_hack_rom_size.ps1`.

## RAM/Screen Read Contract
- `memory_map` uses BRAM-backed RAM and screen.
- BRAM read is synchronous (read data updates on clock edge).
- CPU consumes `inM` from mapped memory output.

## UI Ownership Constraint (Current Top Integration)
- CPU memory bus is connected only when `PAGE_CPU` is active.
- Therefore, continuous `run` mode is allowed only on `PAGE_CPU`.
- Leaving `PAGE_CPU` forces `cpu_run=0` to prevent invalid memory ownership.
- With `CFG_ENABLE_UART_BRIDGE`, any UART bridge command that touches CPU/memory/ROM
  forces `PAGE_CPU` automatically, so remote UART execution remains coherent.
- While UART bridge is active, local TM1638/board control actions are ignored to avoid
  UI-driven page/run overrides during remote execution windows.

## Verification Status
- Implemented reset/boot deterministic testbench:
  - `tb/cpu_core_reset_boot_tb.v`
- Pending:
  - dedicated memory timing testbench covering CPU + memory_map interaction.
