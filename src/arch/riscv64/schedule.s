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
.global current_trap_stack_bottom
.align 4
trapHandlerSupervisor:
    # move *ThreadState from sscratch into t6 and t6 into sscratch
    csrrw t6, sscratch, t6

    # save GPRs
    .set i, 1
    .rept 30
        writeGPR t6, %i
        .set i, i+1
    .endr

    # since a0 is already saved we can move *ThreadState into it
    mv a0, t6

    # move the original t6 value back into t6
    csrr t6, sscratch
    writeGPR a0, 31

    # move *ThreadState back into sscratch
    csrw sscratch, a0

    # save exception PC into *ThreadState
    csrr t0, sepc 
    sd t0, (32 * REGISTER_BYTES)(a0)

    # save previous sstatus
    csrr t0, sstatus
    sd t0, (33 * REGISTER_BYTES)(a0)

    # set trap stack
    ld sp, current_trap_stack_bottom

    # *ThreadState is already in a0
    # pass scause and stval to zig trap handler
    csrr a1, scause
    csrr a2, stval

    call handleTrap

    # load *ThreadState into t6
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

.type forceSchedule, @function
.global forceSchedule
.align 4
forceSchedule:
    # the next thread's *ThreadState is already written to sscratch

    # write *ThreadState to t6
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
