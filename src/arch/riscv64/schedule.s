.section .text

.option norvc

.altmacro

.set REGISTER_BYTES, 8

# 32 GPR + sscratch + pc + sstatus 
.set THREAD_STATE_SSCRATCH_OFF, 32 * REGISTER_BYTES
.set THREAD_STATE_PC_OFF, 33 * REGISTER_BYTES
.set THREAD_STATE_SSTATUS_OFF, 34 * REGISTER_BYTES
.set THREAD_STATE_TRAP_VALUE_OFF, 35 * REGISTER_BYTES
.set THREAD_STATE_TRAP_CAUSE_OFF, 36 * REGISTER_BYTES
.set THREAD_STATE_SIZE, 37 * REGISTER_BYTES

.set THREAD_STATE_USER_SP_OFF, 0 * REGISTER_BYTES
.set THREAD_STATE_KERNEL_SP_OFF, 1 * REGISTER_BYTES

# 1 << 8
.set SSTATUS_SPP_MASK, 0b100000000

.macro writeGPR base, idx
        sd x\idx, ((\idx - 1) * REGISTER_BYTES)(\base)
.endm

.macro readGPR base, idx
        ld x\idx, ((\idx - 1) * REGISTER_BYTES)(\base)
.endm

.type trapHandlerSupervisor, @function
.global trapHandlerSupervisor
.global current_trap_stack_bottom
.align 4
trapHandlerSupervisor:
    # move stack pointer from sscratch into tp and tp into sscratch
    csrrw tp, sscratch, tp

    # if SPP == supervisor
    #   tp = kernel's tp
    #   sscratch = 0
    # else (SPP == user)
    #   tp = user's tp
    #   sscratch = kernel's tp

    bnez tp, .set_stack

    # if tp == 0 then we must set it to the kernel's tp which was swapped to sscratch
    csrr tp, sscratch

.set_stack:
    # save user sp in the struct Thread
    sd sp, THREAD_STATE_USER_SP_OFF(tp)
    # load kernel sp from the struct Thread
    ld sp, THREAD_STATE_KERNEL_SP_OFF(tp)
    # allocate space for struct ThreadState
    addi sp, sp, -THREAD_STATE_SIZE

.save_registers:
    # since x2 is sp and x4 is tp we unroll the first few stores before the main loop
    writeGPR sp, 1
    writeGPR sp, 3

    # save registers from x5 to x32
    .set i, 5
    .rept (32-5)
        writeGPR sp, %i
        .set i, i+1
    .endr

    # save user SP from thread struct to thread state struct
    ld t0, THREAD_STATE_USER_SP_OFF(tp)
    sd t0, (1 * REGISTER_BYTES)(sp)

    # 
    csrr t0, sscratch
    sd t0, (THREAD_STATE_SSTATUS_OFF)(sp)

    csrr t0, sepc
    sd t0, (THREAD_STATE_PC_OFF)(sp)
    csrr t0, sstatus 
    sd t0, (THREAD_STATE_SSTATUS_OFF)(sp)
    csrr t0, stval 
    sd t0, (THREAD_STATE_TRAP_VALUE_OFF)(sp)
    csrr t0, scause
    sd t0, (THREAD_STATE_TRAP_CAUSE_OFF)(sp)

    # since a0 is already saved we can move *ThreadState into it
    mv a0, sp

    # write 0 to sscratch so if another trap occurs it uses the kernel tp
    csrw sscratch, x0

    call handleTrap

    ld t0, (THREAD_STATE_SSTATUS_OFF)(sp)
    and t0, t0, SSTATUS_SPP_MASK
    bnez t0, .load_registers
.set_sscratch:
    # if we are returning to userspace (user mode) then sscratch must contain kernel's tp
    # otherwise 0 which is the current value

    csrrw tp, sscratch, tp
.load_registers:
    ld t0, (THREAD_STATE_PC_OFF)(sp)
    csrw sepc, t0
    ld t0, (THREAD_STATE_SSTATUS_OFF)(sp)
    csrw sstatus, t0

    # since x2 is sp we unroll the first few stores before the main loop
    readGPR sp, 1
    readGPR sp, 3

    # load registers from x4 to x32
    .set i, 4
    .rept (32-5)
        readGPR sp, %i
        .set i, i+1
    .endr

    readGPR sp, 2
    sret

.type forceSchedule, @function
.global forceSchedule
.global riscv64ScheduleNextThread
.align 4
forceSchedule:
