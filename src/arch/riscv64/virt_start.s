
.section .text

.option norvc

.type _start_higher_half, @function
.global _start_higher_half
_start_higher_half:
    .cfi_startproc

.option push
.option norelax

    la gp, __global_pointer
.option pop
    la sp, kernel_stack
    li t0, 65536
    add sp, sp, t0

    la t5, __bss_start
    la t6, __bss_end
bss_clear:
    sd zero, (t5)
    addi t5, t5, 8
    bltu t5, t6, bss_clear

    tail initRiscv64 

loop:
    j loop
    .cfi_endproc
