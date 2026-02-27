// Keyboard -> Screen interactive demo.
// - Mirrors KBD word to RAM[0] for debug.
// - SCREEN[0] = 0xFFFF while any key is pressed, else 0x0000.

(LOOP)
@KBD
// One-cycle wait for synchronous memory read at new A address.
D=D
D=M
@0
M=D
@NO_KEY
D;JEQ

@SCREEN
// Keep one-cycle gap after A update for consistency with sync memory model.
D=D
M=-1
@LOOP
0;JMP

(NO_KEY)
@SCREEN
D=D
M=0
@LOOP
0;JMP
