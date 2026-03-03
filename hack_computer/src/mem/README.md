Memory modules for staged bring-up.

Implemented:
- register_n.v (stage 1)
- ram8_struct.v (stage 2)
- ram64_struct.v (stage 3)
- ram512_struct.v (stage 4)
- ram_bram.v (stage 5)
- ram4k_select.v (stage 6)
- ram16k_select.v (stage 7)
- memory_map.v (stage 8, Hack-style address decode)
- rom32k_prog.v (stage 9, ROM load + PC fetch port)

Planned next blocks:
- CPU-side integration is started (step/run mode in top + rom fetch)
- next: expand to Hack-compatible instruction decode/execute

Experimental:
- DDR3 backend prototype added:
  - `memory_map_ddr3.v` + `ddr3/hack_ddr3_word_store.v`
  - uses Gowin `DDR3_Memory_Interface_Top` and exports `ready` for variable-latency memory.
- It is currently disabled by default (`CFG_ENABLE_DDR3_MEM` commented in `project_config.vh`)
  due to bank VCCIO conflicts with the active 3.3V board IO constraints.

Current FPGA-fit notes (GW2A-18C):
- full 16-bit RAM16K + ROM32K + SCREEN BRAM exceeds on-chip BSRAM.
- temporary build profile uses:
  - ROM in 8K on-chip window (low address quarter)
  - SCREEN BRAM enabled
  - SCREEN size is configurable by `SCREEN_ADDR_W`:
    - 9  -> 512 words (128x64 pixels)
    - 10 -> 1K words
    - 11 -> 2K words
    - 12 -> 4K words
    - 13 -> full Hack screen (8K words)
