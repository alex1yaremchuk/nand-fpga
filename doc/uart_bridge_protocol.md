# UART Bridge Protocol

Binary protocol over UART 8N1.

## Link
- Default baud: `115200`.
- Byte order in multi-byte fields: big-endian.

## Commands
- `0x01 PEEK addr_hi addr_lo`
  - Response: `0x81 data_hi data_lo`
- `0x02 POKE addr_hi addr_lo data_hi data_lo`
  - Response: `0x82`
- `0x03 STEP`
  - Response: `0x83 pc_hi pc_lo a_hi a_lo d_hi d_lo flags`
- `0x04 RUN cyc3 cyc2 cyc1 cyc0`
  - Runs exactly N CPU steps, then responds:
  - Response: `0x84 pc_hi pc_lo a_hi a_lo d_hi d_lo flags`
- `0x05 RESET`
  - Response: `0x85`
- `0x06 STATE`
  - Response: `0x86 pc_hi pc_lo a_hi a_lo d_hi d_lo flags`
- `0x07 KBD data_hi data_lo`
  - Sets keyboard override word.
  - Response: `0x87`
- `0x08 ROMW addr_hi addr_lo data_hi data_lo`
  - Response: `0x88`
- `0x09 ROMR addr_hi addr_lo`
  - Response: `0x89 data_hi data_lo`
- `0x0A HALT`
  - Clears run state.
  - Response: `0x8A`

## Flags byte
- `bit0`: CPU run enabled (`1` running, `0` paused)
- Other bits reserved (currently zero).

## Error response
- Unknown command: `0xFF <cmd>`

## Notes
- Memory/ROM reads are synchronous in RTL; bridge inserts wait states internally.
- Current top integration enables bridge only with `CFG_ENABLE_UART_BRIDGE`.
