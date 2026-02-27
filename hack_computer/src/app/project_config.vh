`ifndef PROJECT_CONFIG_VH
`define PROJECT_CONFIG_VH

// Global data path width. Keep 16 for Hack-compatible machine.
`define DATA_W 16

// Memory profile selection:
// - Default (no extra define): FPGA fit profile.
// - Define HACK_PROFILE_SIM_FULL in simulator build flags for full Hack memory.
//
// Example (iverilog):
//   iverilog -DHACK_PROFILE_SIM_FULL ...
`ifdef HACK_PROFILE_SIM_FULL
    `define CFG_PROFILE_NAME "sim_full"
    `define CFG_ROM_ADDR_W 15          // 32K words
    `define CFG_SCREEN_ADDR_W 13       // 8K words
    `define CFG_USE_SCREEN_BRAM 1
`else
    `define CFG_PROFILE_NAME "fpga_fit"
    `define CFG_ROM_ADDR_W 13          // 8K words
    `define CFG_SCREEN_ADDR_W 13       // 8K words (set 12 for 4K if needed)
    `define CFG_USE_SCREEN_BRAM 1
`endif

`define CFG_RAM16K_USE_BRAM 1
`define CFG_RAM16K_RAM4K_USE_BRAM 1

// UART monitor defaults.
// Enable bridge by adding -DCFG_ENABLE_UART_BRIDGE in build flags.
`define CFG_ENABLE_UART_BRIDGE
`define CFG_UART_BAUD 115200

`endif
