// Canonical rectangle demo (nand2tetris style).
// RAM[0] = rectangle height in rows.
// RAM[1] = stride in SCREEN words per row (8 for 128x64, 32 for 512x256).
// Draws a vertical rectangle in the top-left corner:
// for i in [0..RAM[0)-1]: SCREEN[stride*i] = -1

@0
// One-cycle wait for synchronous memory read at new A address.
D=D
D=M
@END
D;JLE

@SCREEN
D=A
@addr
M=D

(LOOP)
@addr
// One-cycle wait for synchronous memory read at new A address.
D=D
A=M
M=-1

@addr
// One-cycle wait for synchronous memory read at new A address.
D=D
D=M
@1
// One-cycle wait for synchronous memory read at new A address.
D=D
D=D+M
@addr
M=D

@0
// One-cycle wait for synchronous memory read at new A address.
D=D
MD=M-1
@LOOP
D;JGT

(END)
@END
0;JMP
