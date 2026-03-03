# hack-fpga (Tang Nano 20K)

Goal: implement nand2tetris Hack computer on Tang Nano 20K (Gowin GW2AR-18).

Quick resume: `doc/resume_after_reboot.md`

Unified CLI (TUI): `python tools/hack_cli.py`
- One entry point for build/flash, demos, tests, UART utilities, and settings.
- Default settings are saved to `.hack_cli.json` in repo root.

## Status
- [x] RTL simulation flow and CI smoke workflow are running (`.github/workflows/core-smoke.yml`).
- [x] FPGA build + SRAM flash flow is scripted (`flash_blink_sram.cmd`).
- [x] UART bridge tooling is in place (state/memory/ROM/run/control + viewer + keyboard input).
- [x] CPU baseline programs run on hardware with golden comparison support.
- [x] Python toolchain stages are in place (`ASM -> VM -> Jack`) with sim/hardware smoke wrappers.

## Execution Plan
Track: keep one RTL codebase with two memory profiles.

### Phase 1: Profiles and Memory Baseline
- [x] Add `fpga_fit` profile (reduced ROM, configurable screen size).
- [x] Add `sim_full` profile (ROM32K + RAM16K + SCREEN8K) for PC RTL simulation.
- Current `fpga_fit` ROM window: 16K words (`ROM_ADDR_W=14`, 32768 bytes).
- Current `fpga_fit` screen window: 128x64 pixels (`SCREEN_ADDR_W=9`, 512 words).
- [x] Centralize profile knobs in `hack_computer/src/app/project_config.vh`.
- [x] Guard ROM against address wrap for reduced ROM profiles.
- [x] Add host-side ROM size checker (`tools/check_hack_rom_size.ps1`).

Quick check command:
- `powershell -ExecutionPolicy Bypass -File tools/check_hack_rom_size.ps1 -HackFile path/to/program.hack -Profile fpga_fit`

### Phase 2: Computer Core Stability
- [x] Document CPU+memory timing contract (`doc/cpu_memory_timing.md`).
- [x] Add dedicated CPU+memory timing testbench (`tb/cpu_memory_timing_tb.v`).
- [x] Run CPU testbenches locally with Icarus (`PASS`).
- [x] Add CI wiring for core smoke and persist test artifacts:
  - `tools/run_cpu_core_tb.ps1`
  - `tools/run_cpu_memory_timing_tb.ps1`
  - `tools/run_hack_runner_smoke.ps1`
  - `tools/run_baseline_program_tests.ps1 -Profile sim_full`
  - upload `build/*` dumps/logs/waveforms as CI artifacts.
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
- `powershell -ExecutionPolicy Bypass -File tools/run_hack_asm_tests.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_hack_vm_tests.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_hack_jack_tests.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_pipeline_smoke.ps1 -JackInput tools/programs/JackSmokeSys.jack -Profile sim_full -Cycles 200 -ExpectAddr 16 -ExpectValue 5 -Bootstrap`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_fpga_smoke.ps1 -Port COM7 -Profile fpga_fit -JackInput tools/programs/JackSmokeSys.jack -Cycles 200 -ExpectAddr 16 -ExpectValue 5 -Bootstrap`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_pipeline_smoke.ps1 -JackInput tools/programs/JackDirSmoke -Profile sim_full -Cycles 300 -ExpectAddr 16 -ExpectValue 4 -Bootstrap`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_fpga_smoke.ps1 -Port COM7 -Profile fpga_fit -JackInput tools/programs/JackDirSmoke -Cycles 300 -ExpectAddr 16 -ExpectValue 4 -Bootstrap`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_corpus_sim.ps1 -Profile sim_full`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_corpus_fpga.ps1 -Port COM7 -Profile fpga_fit`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_corpus_sim.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_sim.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_os_compile_smoke.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_fpga_subset_sim.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_fpga_subset_hw.ps1 -Port COM7 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch -Port COM7`
- `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch -Port COM7 -Project12Extended`
- `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch -Port COM7 -Project12Extended -FailOnFpgaFitBudgetOverflow`
- `powershell -ExecutionPolicy Bypass -File tools/run_bram_final_regression.ps1 -Fetch -Port COM7`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_api_smoke.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_compile_smoke.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_strict_smoke.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_strict_smoke.ps1 -Fetch -IncludeStringTest -IncludeExtendedTests -CompactStringLiterals -VmSyncWaits 1 -ReportFpgaFitBudget`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_api_smoke.ps1 -Fetch -IncludeStringTest`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_api_smoke.ps1 -Fetch -IncludeExtendedTests`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_api_smoke.ps1 -Fetch -IncludeStringTest -IncludeExtendedTests`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_string_runtime_smoke.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_keyboard_runtime_smoke.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_keyboard_char_runtime_smoke.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_runtime_extended_smoke.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/run_vm_pipeline_smoke.ps1 -VmInput tools/programs/VmSmokeSys.vm -Profile sim_full -Cycles 200 -ExpectAddr 5 -ExpectValue 5 -Bootstrap`
- `powershell -ExecutionPolicy Bypass -File tools/run_vm_fpga_smoke.ps1 -Port COM7 -Profile fpga_fit -VmInput tools/programs/VmSmokeSys.vm -Cycles 200 -Bootstrap`
- `powershell -ExecutionPolicy Bypass -File tools/check_fpga_fit_resource_budgets.ps1`
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
- `python tools/hack_uart_client.py --port COM5 diag`
- `python tools/hack_uart_client.py --port COM5 watch --words-per-row 8 --rows 8 --interval 0.2`
- `python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 32 --auto-run`
- `python tools/hack_uart_client.py --port COM5 runhack --hack-file build/rect_visual_demo/RectCanonical.hack --cycles 400 --rom-addr-w 14 --ram-base 0 --ram-words 2 --screen-words 512 --clear-screen-words 512 --out-dir build/fpga_uart_rect`
  - If your terminal flickers/artifacts, add `--interval 0.15` or `--no-clear`.

Quick visual checks:
1. PC-only (`sim_full`/`fpga_fit`, no FPGA):
   - `powershell -ExecutionPolicy Bypass -File tools/run_rect_visual_demo.ps1 -Profile fpga_fit`
   - See ASCII preview in terminal and image `build/rect_visual_demo/screen.pbm`.
2. UART on FPGA:
   - Single terminal: `python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 32 --auto-run`
   - Controls: `q` quit, `space` run/pause, `r` reset, `s` state, `x` key up.
   - `watch` still exists, but it is read-only and cannot share port with a second client.

### Phase 5: Hardware End-to-End
- [x] Run `Rect` on FPGA via UART viewer and verify rendering workflow (one-command script).
- [x] Run an interactive keyboard-driven program via UART.
- [x] Correlate FPGA dumps vs simulation dumps for same programs.
- [x] Harden strict debug-state parity (`PC/A/D`) in FPGA-vs-golden compare flow.

Hardware correlation command:
- `powershell -ExecutionPolicy Bypass -File tools/compare_fpga_uart_against_golden.ps1 -Port COM5 -Profile fpga_fit`
- Add `-StrictPcDump` to also require `D` and `A` register match in `pc_dump.txt` (default compares only `PC`).
  - Strict mode now runs without per-test variance exceptions.
- Hardware compare enables ROM write verification/retry to avoid UART programming glitches.

Interactive keyboard demo (single command):
- `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_interactive_demo.ps1 -Port COM5`
- Program: `tools/programs/KeyboardScreen.asm` (`KBD` controls `SCREEN[0]`, key code mirrored to `RAM[0]`).
- Viewer now sends periodic `kbd=0` heartbeat in interactive mode to avoid stale key override during long UART sessions.
- Automated smoke check:
  - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_uart_smoke.ps1 -Port COM5`
  - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_uart_soak.ps1 -Port COM5 -Iterations 40`
  - `powershell -ExecutionPolicy Bypass -File tools/run_keyboard_uart_latency.ps1 -Port COM5 -Iterations 40 -P95ThresholdMs 150`

Snake demo (single command):
- `powershell -ExecutionPolicy Bypass -File tools/run_snake_demo.ps1 -Port COM5`
- Controls inside viewer: `W/A/S/D` or arrows (plus viewer controls `q`, `space`, `r`, `s`, `x`).
- Snake demo defaults use viewer game mode for stability: sticky direction input + non-delta rendering (`run-cycles=24000`, `interval=0.08`).
- Load-only mode: `powershell -ExecutionPolicy Bypass -File tools/run_snake_demo.ps1 -Port COM5 -NoViewer`

Rect live viewer demo (single command):
- `powershell -ExecutionPolicy Bypass -File tools/run_rect_uart_viewer_demo.ps1 -Port COM5`
- Viewer auto-clamps `words-per-row` to terminal width to prevent wrapped/asymmetric ASCII frames.
- `RectCanonical` now uses `RAM[1]` as stride (`8` for `fpga_fit`, `32` for `sim_full`), so one demo program works for both geometries.

### Phase 6: UART UX and Input Robustness
- [ ] Stabilize viewer rendering for long sessions (no stale header/artifacts).
- [x] Make `Rect` demo visually unambiguous (canonical rectangle program + deterministic RAM init).
- [x] Eliminate keyboard "first key only"/lag behavior in interactive mode.
- [x] Add repeatable host-side regression for key press/release timing.
- [x] Gate keyboard hardware smoke with soak + latency + protocol diagnostic deltas.

Remaining changes:
- Add an automated long-session viewer soak (>=30 min) with pass/fail criteria for frame stability.
- Capture compact viewer artifacts/log summary from soak runs for regression triage.

Exit criteria:
- `run_rect_uart_viewer_demo` shows expected shape in a fresh terminal session and during a 30-minute run with no stale header/artifacts.
- `run_keyboard_interactive_demo` handles repeated key presses with no sticky key code in 3 consecutive runs.
- `run_keyboard_uart_smoke` + soak check pass 3 consecutive runs on hardware with zero stuck key events.
- Measure and record key-to-screen latency; target p95 <= 150 ms (or update this threshold based on measured board/baud limits).
  - Latest hardware sample (COM7, 40 iterations): p95 press latency = 70.00 ms.

### Phase 6.5: UART Protocol Hardening
- [x] Add protocol-level reliability for long sessions (sequence id/ack + bounded retry policy).
- [x] Add bounded host-side UART transfer retries with input-drain resync on short reads/unexpected responses.
- [x] Add explicit resync path after malformed/partial frames.
- [x] Add telemetry counters (`rx_err`, `retry_count`, `desync_count`) exposed in host diagnostics.
- [x] Gate hardware smoke on "no protocol errors" over a fixed soak duration.
  - `DIAG` now reports `seq_capable` (reserved bit0), and host `hack_uart_client.py` uses `--seq-mode auto` by default:
    - probes capability safely via `DIAG`,
    - uses `CMD_SEQ` wrapper when available,
    - keeps backward compatibility with legacy bitstreams.

### Phase 7: Software Stack Bootstrapping
- [x] 7A: Assembler hardening and spec-complete tests.
- [x] 7B: VM translator core (stack arithmetic, memory segments, branching).
- [x] 7C: VM call/return + bootstrap + directory mode.
- [x] End-to-end pipeline scripts: `Jack -> VM -> ASM -> HACK -> FPGA run`.
- [x] Add resource budget tracking gates for `fpga_fit` (ROM/RAM/SCREEN) in toolchain scripts and CI.
- [x] Define golden update policy (when `tools/baseline_golden` can be regenerated and what evidence is required).

Toolchain language strategy (Python-first):
- [x] Keep assembler/VM/Jack toolchain in Python for one-language maintenance and fast iteration.
- [x] Expand fixture-based tests (`positive + negative`) before adding new compiler stages.
- [x] Ship stable CLI entry points for each stage:
  - `tools/hack_asm.py` (`.asm -> .hack`)
  - `tools/hack_vm.py` (`.vm -> .asm`)
  - `tools/hack_jack.py` (`.jack -> .vm`; optional token XML via `--tokens-out`)
- [ ] Re-evaluate non-Python implementation only if concrete distribution/runtime constraints appear.

Assembler track:
- [x] Expand `tools/hack_asm.py` tests for labels/variables/error cases (`tools/tests/test_hack_asm.py`).
- [x] Freeze output compatibility against nand2tetris reference examples (`tools/tests/asm_fixtures/n2t_add.asm`).
- [x] Add parity harness between parser/encoder stages and frozen `.hack` golden fixtures (`tools/tests/asm_fixtures/*.asm/.hack`).

VM translator track:
- [x] Start with single-file VM programs; then directory mode with bootstrap.
- [x] Add baseline VM fixtures and golden `.asm` outputs (`tools/tests/vm_fixtures/*.vm/.asm`).
- [x] Add FPGA smoke command for translated VM samples (`tools/run_vm_fpga_smoke.ps1`).
- [x] Keep strict output compatibility checks against frozen golden fixtures.

VM translator command:
- `python tools/hack_vm.py path/to/program.vm -o path/to/program.asm`
- `python tools/hack_vm.py path/to/program_directory -o build/Program.asm` (default enables bootstrap for directory mode)
- `python tools/hack_vm.py path/to/program_directory -o build/Program.asm --bootstrap --sync-waits 1` (smaller code, still sync-safe in current sim pipeline)

### Phase 8: Jack + OS Track
- [x] Jack tokenizer/parser/symbol table/compiler to VM.
- [x] Run repo Jack corpus (`tools/programs/JackCorpus`) in `sim_full` first.
- [x] Run repo Jack corpus on FPGA (`fpga_fit`) via UART smoke harness.
- [x] Add runtime smoke checks for official non-interactive Jack programs in `sim_full` (minimal OS stubs).
- [ ] Bring up OS components incrementally (Screen, Keyboard, Math, Memory, String, Sys).
- [x] Import and run the official nand2tetris Jack corpus compile pipeline in `sim_full` (`tools/run_jack_official_corpus_sim.ps1`).
- [x] Extend official runtime checks to interactive `Square` / `Pong` (scripted keyboard input) in `sim_full`.
- [ ] Replace minimal runtime stubs with real OS components and tighten behavior checks.

Phase 8 next concrete steps:
- [x] Add a staged runtime mode in smoke scripts (`stubs -> hybrid -> full`) to migrate off `*Lite` stubs safely.
- [x] Compile official project-12 OS Jack sources via `hack_jack.py` and run compile/run smoke on compiled OS in `sim_full` (`RuntimeMode=os_jack`, `CheckMode=compile`).
- [x] Promote `RuntimeMode=os_jack` to strict behavioral checks for project-12 core API cases (`ArrayTest`, `MemoryTest`, `MathTest`) using local Jack runtime sources (`tools/programs/JackOfficialRuntimeJack`).
- [x] Expand `RuntimeMode=os_jack` strict coverage to `StringTest` and extended IO/interactive cases (`OutputTest`, `ScreenTest`, `SysTest`, `KeyboardTest`).
- [x] Keep ROM-budget gate visible during OS migration (`tools/check_profile_resource_budget.ps1` + smoke reports + BRAM final core gate).
- [x] After `sim_full` stabilization, define a reduced `fpga_fit` runtime subset and add dedicated smoke flows (`tools/run_jack_official_runtime_fpga_subset_sim.ps1`, `tools/run_jack_official_runtime_fpga_subset_hw.ps1`).

Current baseline:
- Runtime smokes and project-12 API checks are currently driven by VM runtime stubs from `tools/programs/JackOfficialRuntimeStubs`.
- Project-12 API strict checks (core + optional String/extended cases) can run against local Jack runtime sources (`tools/programs/JackOfficialRuntimeJack`) via `-RuntimeMode os_jack`.
- `tools/run_jack_project12_api_smoke.ps1` already supports broader coverage via `-IncludeStringTest` and `-IncludeExtendedTests`.
- `fpga_fit` runtime subset default is now validated on `Seven`, `ConvertToBin`, `Average`, and `Square` using lightweight runtime stubs (`tools/programs/JackOfficialRuntimeFpgaSubsetStubs`), with default `VmSyncWaits=1` and a per-case override `ConvertToBin -> 2` for hardware parity.
- Project-12 core OS cases (`ArrayTest`, `MemoryTest`, `MathTest`) now fit `fpga_fit` ROM16K in strict mode when using:
  - per-case runtime class linking (`RuntimeClasses`) in `os_jack` mode,
  - `-CompactStringLiterals`,
  - `-VmSyncWaits 1`.
- `ComplexArrays` remains available via explicit `-Case ComplexArrays`, but does not fit current `fpga_fit` ROM16K budget with stubs.

Jack track (current incremental status):
- [x] Tokenizer implemented with XML token output (`tools/hack_jack.py`, `tools/tests/test_hack_jack.py`).
- [x] Parser + symbol table.
- [x] VM code generation (`.jack -> .vm`).
- [x] Jack end-to-end smoke (`Jack -> VM -> ASM -> HACK -> sim_full` and FPGA smoke wrappers, single-file + directory).
- [ ] Expand compiler coverage against full nand2tetris Jack corpus and OS-heavy programs.

Jack commands:
- `python tools/hack_jack.py path/to/file.jack -o path/to/file.vm`
- `python tools/hack_jack.py path/to/jack_project_dir -o path/to/vm_out_dir`
- `python tools/hack_jack.py path/to/file.jack --tokens-out path/to/file.tokens.xml`
- `python tools/hack_jack.py path/to/jack_project_dir -o path/to/vm_out_dir --compact-string-literals` (smaller VM for string-heavy programs)
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_corpus_sim.ps1 -Profile sim_full`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_corpus_fpga.ps1 -Port COM7 -Profile fpga_fit`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_corpus_sim.ps1 -Fetch`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_sim.ps1 -Fetch`
  - Runtime staging: add `-RuntimeMode hybrid` to replace core `*Lite` runtime classes with full variants.
  - Runtime staging: add `-RuntimeMode full` for supported cases (currently safe default subset; use `-Case` for explicit selection).
  - Profile-selectable budgets/runner: add `-Profile sim_full|fpga_fit`.
  - ROM-fit tuning knob: add `-VmSyncWaits N` (for `fpga_fit` subset default `N=1`; `ConvertToBin` uses a per-case override `N=2`).
  - OS source compile smoke: `-RuntimeMode os_jack -CheckMode compile` (or wrapper `tools/run_jack_official_runtime_os_compile_smoke.ps1`).
  - Runtime-verified today: `Seven`, `Average`, `ComplexArrays`, `ConvertToBin`, `Square`, `Pong` (via `tools/programs/JackOfficialRuntimeStubs`).
  - Interactive runtime checks now validate both RAM progress markers and non-zero `SCREEN[0]` activity for `Square`/`Pong`.
  - Runtime checks also validate `Output.printString` trace markers (`RAM[3700]`) for `Average` and `ComplexArrays`.
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_fpga_subset_sim.ps1 -Fetch`
  - Runs reduced `fpga_fit` strict subset: `Seven`, `ConvertToBin`, `Average`, `Square` (`RuntimeMode=stubs`, default `VmSyncWaits=1`, `ConvertToBin` override `2`).
  - `ComplexArrays` is optional (`-Case ComplexArrays`) and currently ROM-limited on `fpga_fit`.
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_official_runtime_fpga_subset_hw.ps1 -Port COM7 -Fetch`
  - Builds the same reduced subset and runs it on FPGA via UART `runhack` with post-run RAM/SCREEN checks (`eq/ne/ge/gt/le/lt`).
- `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch`
  - One-command daily sim bundle (`asm/vm/jack unit tests`, pinned `fpga_fit` subset sim gate: `Seven/ConvertToBin/Average/Square`, `project12 os_jack strict` subset) with unified summary.
- `powershell -ExecutionPolicy Bypass -File tools/run_daily_regression_bundle.ps1 -Fetch -Port COM7`
  - Same bundle plus pinned hardware `fpga_fit` runtime subset gate (`Seven/ConvertToBin/Average/Square`).
  - Add `-Project12Extended` to run full+extended `os_jack strict` suite with shrink knobs (`-CompactStringLiterals -VmSyncWaits 1`) and `fpga_fit` budget report.
  - Add `-FailOnFpgaFitBudgetOverflow` to make fpga-fit ROM overflow a hard failure in that extended mode (recommended strict gate).
- `powershell -ExecutionPolicy Bypass -File tools/run_bram_final_regression.ps1 -Fetch -Port COM7`
  - BRAM-oriented "ship gate": unit tests + pinned runtime subset (sim/hw) + `os_jack` strict core (`Array/Memory/Math`) with hard fpga-fit budget enforcement.
  - Explicitly treats extended `os_jack` fpga-fit overflows as non-goals for current ROM16K budget.
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_api_smoke.ps1 -Fetch`
  - Runtime staging: add `-RuntimeMode hybrid|full` (full mode intentionally restricted for cases that rely on stub-driven IO traces).
  - Local Jack runtime strict mode: add `-RuntimeMode os_jack -CheckMode strict`.
  - OS source compile smoke: `tools/run_jack_project12_os_compile_smoke.ps1` (`RuntimeMode=os_jack -CheckMode compile`).
  - OS strict smoke wrapper: `tools/run_jack_project12_os_strict_smoke.ps1` (`RuntimeMode=os_jack -CheckMode strict`).
  - Base cases: `ArrayTest`, `MemoryTest`, `MathTest`.
  - Optional: `-IncludeStringTest` (`StringTest`; uses compact Jack string literals + VM `--sync-waits 1` for ROM fit).
  - Optional: `-IncludeExtendedTests` (`OutputTest`, `ScreenTest`, `SysTest`, `KeyboardTest` with scripted checks and RAM init).
  - Global size/perf knobs: `-CompactStringLiterals` and `-VmSyncWaits N`.
  - `KeyboardTest` in extended mode also uses compact Jack string literal emission plus VM `--sync-waits 1` to stay within `sim_full` ROM.
  - `-ReportFpgaFitBudget` adds per-case fpga-fit ROM/RAM/SCREEN budget status to summary (`fpga_fit_budget_summary.txt`).
  - `-FailOnFpgaFitBudget` makes fpga-fit budget overflow fail the run.
  - Core fpga-fit strict example:
    - `powershell -ExecutionPolicy Bypass -File tools/run_jack_project12_os_strict_smoke.ps1 -Case ArrayTest,MemoryTest,MathTest -CompactStringLiterals -VmSyncWaits 1 -ReportFpgaFitBudget -FailOnFpgaFitBudget`
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_string_runtime_smoke.ps1`
  - Validates `String.setInt` / `String.intValue` behavior (`0`, positive, negative) and output trace markers in RAM.
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_keyboard_runtime_smoke.ps1`
  - Validates `Keyboard.readInt` fallback (`readLine` + `String.intValue`) and scripted `readLine` behavior.
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_keyboard_char_runtime_smoke.ps1`
  - Validates scripted `Keyboard.readChar` buffer and fallback to `keyPressed`.
- `powershell -ExecutionPolicy Bypass -File tools/run_jack_runtime_extended_smoke.ps1`
  - Runs `string + keyboard-int + keyboard-char` runtime smokes and writes a unified summary.

### Phase 9: Developer UX and CI
- [x] Provide a unified interactive CLI/TUI (`tools/hack_cli.py`) for build/flash, demos, tests, UART tools, and settings.
- [x] Persist local defaults in `.hack_cli.json` (port, baud, viewer geometry, cable/device).
- [x] Expose hardware and sim smoke paths from one entry point.
- [x] Add CI smoke workflow (`.github/workflows/core-smoke.yml`) with artifact upload.
- [x] Add a scripted "daily regression bundle" command (single command for core sim + selected hardware gates).
- [x] Add explicit CLI presets for common contexts (`bram_final`, `sim_only`, `fpga_fast`, `fpga_full`).
  - `bram_final`: recommended BRAM completion gate (sim + hardware subset + project12 core strict budget gate).
  - `sim_only`: daily regression bundle in sim mode.
  - `fpga_fast`: pinned hardware runtime subset (`Seven/ConvertToBin/Average/Square`).
  - `fpga_full`: legacy extended bundle with strict fpga-fit budget fail and fail-fast behavior.
    - Note: currently expected to fail until remaining extended `os_jack` cases fit ROM16K.

Execution notes:
- Default target for new language/runtime work: `sim_full`.
- Keep `fpga_fit` as hardware validation target.
- ROM capacity decisions are deferred until we hit concrete size limits with VM/Jack workloads.
- Golden update policy: `doc/golden_update_policy.md`.
- DDR3 experiment status (2026-03-03):
  - Added experimental DDR3 data-memory backend (`memory_map_ddr3`, `hack_ddr3_word_store`) and UART `mem_ready` handshake support.
  - Default build keeps DDR3 path disabled (`project_config.vh`: `CFG_ENABLE_DDR3_MEM` commented) because enabling it with current board constraints causes bank VCCIO conflicts (`SSTL15 1.5V` vs existing `3.3V` IO, Gowin `CT1136`).
  - Reference DDR3 pin map is stored in `hack_computer/src/constraints/hack_computer_ddr3_experimental.cst` (not included in default project constraints).

## Project Layout
- `hack_computer/src/app`: top-level integration (`top.v`) and global config.
- `hack_computer/src/core`: core compute blocks (ALU, later CPU blocks).
- `hack_computer/src/io`: UART bridge, TM1638, and input conditioning.
- `hack_computer/src/mem`: memory modules (in progress).
- `hack_computer/src/constraints`: board pin constraints.
