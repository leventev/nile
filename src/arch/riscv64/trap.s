.section .text

.option norvc

.altmacro
.set REGISTER_BYTES, 8

.macro writeGPR base_reg, i
    sd x\i, ((\i) * REGISTER_BYTES)(\base_reg)
.endm

.macro readGPR base_reg, i
    ld x\i, ((\i) * REGISTER_BYTES)(\base_reg)
.endm

.type trapHandlerSupervisor, @function
.global trapHandlerSupervisor
.global trap_stack_bottom
.align 4
trapHandlerSupervisor:
    # move *Registers from sscratch into t6 and t6 into sscratch
    csrrw t6, sscratch, t6

    # save GPRs
    .set i, 1
    .rept 30
        writeGPR t6, %i
        .set i, i+1
    .endr

    # since t1 is already saved we can move *Registers into it
    mv t1, t6
    # move the original t6 value back into t6
    csrr t6, sscratch
    writeGPR t1, 31

    # move *Registers back into sscratch
    csrw sscratch, t1

    # save exception PC into *Registers
    csrr t0, sepc 
    sd t0, (32 * REGISTER_BYTES)(t1)

    # save previous sstatus
    csrr t0, sstatus
    sd t0, (33 * REGISTER_BYTES)(t1)

    # set trap stack
    ld sp, trap_stack_bottom

    # pass scause and stval to zig trap handler
    csrr a0, scause
    csrr a1, stval
    # pass *Registers to zig trap handler
    mv a2, t1

    call handleTrap

    # load *Registers into t6
    csrr t6, sscratch

    ld t0, (32 * REGISTER_BYTES)(t6)
    csrw sepc, t0

    ld t0, (33 * REGISTER_BYTES)(t6)
    csrw sstatus, t0

    # load GPRs
    # NOTE: it can seem that we are rewriting t6 here but t6 is the last register thus writing all 30
    # registers before it is fine
    .set i, 1
    .rept 31
        readGPR t6, %i
        .set i, i + 1
    .endr

    sret
