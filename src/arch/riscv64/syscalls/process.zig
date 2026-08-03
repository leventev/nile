const std = @import("std");
const processes = @import("../../../processes.zig");
const syscall_proc = @import("../../../syscall/process.zig");

const core = @import("core");

pub fn spawn(args: [7]u64) core.SyscallResult {
    const executable_fd: u64 = @bitCast(args[0]);
    const flags: core.process.SpawnFlags = @bitCast(args[1]);

    return syscall_proc.spawn(
        executable_fd,
        flags,
    );
}
