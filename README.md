# hack-fpga (Tang Nano 20K)

Goal: implement nand2tetris Hack computer on Tang Nano 20K (Gowin GW2AR-18).

## Status
- [ ] Toolchain installed
- [ ] JTAG programming works
- [ ] UART monitor works
- [ ] ALU on hardware
- [ ] CPU on hardware

## Project Layout
- `hack_computer/src/app`: top-level integration (`top.v`) and global config.
- `hack_computer/src/core`: core compute blocks (ALU, later CPU blocks).
- `hack_computer/src/io`: TM1638 and input conditioning.
- `hack_computer/src/mem`: memory modules (in progress).
- `hack_computer/src/constraints`: board pin constraints.
