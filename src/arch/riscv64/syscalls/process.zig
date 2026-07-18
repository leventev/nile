const std = @import("std");
const processes = @import("../../../processes.zig");
const syscall_proc = @import("../../../syscall/process.zig");
const errors = @import("../../../syscall/errors.zig");

pub fn spawn(args: [7]u64) !u64 {
    const executable_fd: u64 = @bitCast(args[0]);
    const flags: syscall_proc.SpawnFlags = @bitCast(args[1]);

    return syscall_proc.spawn(
        executable_fd,
        flags,
    );
}
