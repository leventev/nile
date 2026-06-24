const std = @import("std");
const builtin = @import("builtin");
const riscv64 = @import("riscv64.zig");

pub const test_constant = 1;

pub fn sysExit(exit_code: usize) noreturn {
    riscv64.sysExit(exit_code);
}

pub fn sysOpenat(dirfd: i64, path: []const u8, flags: u64, mode: u64) i64 {
    return riscv64.sysOpenat(dirfd, path, flags, mode);
}

pub fn sysRead(fd: u32, buff: []u8) i64 {
    return riscv64.sysRead(fd, buff);
}

pub fn sysWrite(fd: u32, buff: []const u8) i64 {
    return riscv64.sysWrite(fd, buff);
}
