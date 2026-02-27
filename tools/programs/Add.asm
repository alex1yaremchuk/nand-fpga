// RAM[2] = RAM[0] + RAM[1]
@0
D=M
@1
// One-cycle wait for synchronous memory read at new A address.
D=D
D=D+M
@2
M=D
(END)
@END
0;JMP
