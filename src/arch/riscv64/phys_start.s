.section .text

.set KERNEL_PHYS_REG_START, 0x80000000
.set KERNEL_OFFSET, 0xffffffffc0000000
; .set KERNEL_OFFSET, KERNEL_VIRT_REG_START - KERNEL_PHYS_REG_START
.set KERNEL_MAPPING_FLAGS, 0b101111
.set KERNEL_MAPPING, (KERNEL_PHYS_REG_START >> 2) | KERNEL_MAPPING_FLAGS

.type _start, @function
.global _start
_start:
    # reference for values:
    # https://docs.riscv.org/reference/isa/_attachments/riscv-privileged.pdf
    li t0, KERNEL_MAPPING
    la t1, root_pg_tbl

    # identity map
    sd t0, 2 * 8(t1)

    # higher half
    li t2, 4096
    add t1, t1, t2
    sd t0, -1 * 8(t1)

    # load SATP

    # set mode to Sv39
    li t2, 0b1000
    slli t2, t2, 60
    
    # page number of page table
    la t1, root_pg_tbl
    srli t1, t1, 12

    # page number and flag together
    or t1, t1, t2

    csrw satp, t1
    sfence.vma

    la a2, root_pg_tbl

    lui  t0, %hi(_start_higher_half)
    addi t0, t0, %lo(_start_higher_half)
    jalr ra, t0

loop:
    j loop

.section .data
.global root_pg_tbl
.align 12
root_pg_tbl: .space 4096

