// Variable/label fixture
@counter
M=0
(LOOP)
@counter
M=M+1
@10
D=A
@counter
D=D-M
@LOOP
D;JGT
@END
0;JMP
(END)
@END
0;JMP
