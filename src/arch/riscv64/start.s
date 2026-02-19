.section .init

.option norvc

.type _start, @function
.global _start
_start:
    .cfi_startproc

.option push
.option norelax
    la gp, __global_pointer
.option pop
    csrw satp, zero

    csrw sie, zero

    la sp, __stack_top

    la t5, __bss_start
    la t6, __bss_end
bss_clear:
    sd zero, (t5)
    addi t5, t5, 8
    bltu t5, t6, bss_clear

    la t0, device_tree_pointer
    sd a1, (t0)
    tail kmain

loop:
    j loop
    .cfi_endproc
.end
