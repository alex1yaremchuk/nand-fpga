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

Current FPGA-fit notes (GW2A-18C):
- full 16-bit RAM16K + ROM32K + SCREEN BRAM exceeds on-chip BSRAM.
- temporary build profile uses:
  - ROM in 8K on-chip window (low address quarter)
  - SCREEN BRAM enabled
  - SCREEN size is configurable by `SCREEN_ADDR_W`:
    - 13 -> full Hack screen (8K words)
    - 12 -> 4K words
    - 11 -> 2K words
