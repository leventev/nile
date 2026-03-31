.section .text

.set KERNEL_PHYS_REG_START, 0x80000000
.set KERNEL_OFFSET, 0xffffffffc0000000
.set KERNEL_MAPPING_FLAGS, 0b101111
.set KERNEL_MAPPING, (KERNEL_PHYS_REG_START >> 2) | KERNEL_MAPPING_FLAGS

.type _start, @function
.global _start
_start:
    # OpenSBI gets loaded to 0x80000000 in qemu-virt
    # then OpenSBI loads the kernel at 0x80200000 and enters supervisor mode

    # initialization process:
    # 1. setup virtual memory
    #   1. identity map 0x80000000-0xc0000000(root_pg_tbl[2])
    #   2. map 0x80000000-0xc0000000 to 0xffffffffc0000000-0xfffffffff0000000(root_pg_tbl[511])
    #   3. write root_pg_tbl's physical address and Sv39 mode to SATP
    #   4. write SATP CSR which enables paging, since the kernel is identity mapped
    #      execution continues
    #   5. flush TLB with sfence.vma x0, x0 (TODO: not sure whether this is necessary?)
    # 2. load __global_pointer to 'gp'
    # 3. load stack bottom(= stack top + stack size) to 'sp'
    # 4. fill .bss with 0s(TODO: does OpenSBI do this?)
    # 5. jump to 'initRiscv64' in zig code
    # 

    # reference for values:
    # https://docs.riscv.org/reference/isa/_attachments/riscv-privileged.pdf
    li t0, KERNEL_MAPPING
    la t1, root_pg_tbl

    # identity map
    sd t0, 2 * 8(t1)

    # map higher half
    li t2, 4096
    add t1, t1, t2
    sd t0, -1 * 8(t1)

    # set mode to Sv39
    li t2, 0b1000
    slli t2, t2, 60
    
    # page number of page table
    la t1, root_pg_tbl
    srli t1, t1, 12

    # page number and flag together
    or t1, t1, t2

    # load SATP and flush TLB
    csrw satp, t1
    sfence.vma

.option push
.option norelax
    lui gp, %hi(__global_pointer)
    addi gp, gp, %lo(__global_pointer)
.option pop

    # load stack top
    lui sp, %hi(init_kernel_stack)
    addi sp, sp, %lo(init_kernel_stack)

    # load stack size value
    lui t0, %hi(init_kernel_stack_size)
    addi t0, t0, %lo(init_kernel_stack_size)
    ld t1, 0(t0)

    # sp <- stack bottom = stack top + stack size
    add sp, sp, t1

    lui t5, %hi(__bss_start)
    addi t5, t5, %lo(__bss_start)

    # clear .bss with 0s
    # its assumed the size is divisible by 8

    lui t6, %hi(__bss_end)
    addi t6, t6, %lo(__bss_end)
bss_clear:
    sd zero, (t5)
    addi t5, t5, 8
    bltu t5, t6, bss_clear

    # a0 contains the hart ID (OpenSBI)
    # a1 contains a physical pointer to device tree (OpenSBI)

    # set a2 to the root_pg_tbl because it's located in .lh_data
    # and the higher half zig code won't be able to directly access it
    # because of relocations
    la a2, root_pg_tbl

    # jump to zig code
    lui  t0, %hi(initRiscv64)
    addi t0, t0, %lo(initRiscv64)
    jalr ra, t0

loop:
    j loop

.section .data
.global root_pg_tbl
.align 12
root_pg_tbl: .space 4096

