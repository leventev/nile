const std = @import("std");
const core = @import("core");
const riscv64 = @import("riscv64.zig");

pub fn sysExit(exit_code: isize) noreturn {
    riscv64.sysExit(exit_code);
}

pub fn sysOpenat(dirfd: i64, path: []const u8, flags: u64, mode: u64) core.SyscallResult {
    return riscv64.sysOpenat(dirfd, path, flags, mode);
}

pub fn sysRead(fd: u32, buff: []u8) core.SyscallResult {
    return riscv64.sysRead(fd, buff);
}

pub fn sysWrite(fd: u32, buff: []const u8) core.SyscallResult {
    return riscv64.sysWrite(fd, buff);
}

pub fn sysSpawn(executable_fd: u32, flags: u64) core.SyscallResult {
    return riscv64.sysSpawn(executable_fd, flags);
}
