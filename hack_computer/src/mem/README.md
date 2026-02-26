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

Planned next blocks:
- CPU-side integration with A/D/M datapath and ROM fetch
