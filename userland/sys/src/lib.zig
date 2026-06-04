const std = @import("std");
const builtin = @import("builtin");
const riscv64 = @import("riscv64.zig");

pub const test_constant = 1;

pub fn sysExit(exit_code: usize) noreturn {
    riscv64.sysExit(exit_code);
}
