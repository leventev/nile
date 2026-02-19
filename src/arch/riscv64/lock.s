.section .text

.option norvc


.type __riscv64_lock, @function
.align 4
.global __riscv64_lock
__riscv64_lock:
  li t0, 1
  amoswap.d.aq t0, t0, (a0)
  bnez t0, __riscv64_lock
  ret


.type __riscv64_unlock, @function
.align 4
.global __riscv64_unlock
__riscv64_unlock:
  amoswap.d.aq zero, zero, (a0)
  ret
