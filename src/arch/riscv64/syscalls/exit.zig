const std = @import("std");
const core = @import("core");
const processes = @import("../../../processes.zig");

pub fn exit(args: [7]u64) core.SyscallResult {
    const exit_code: isize = @bitCast(args[0]);
    processes.killCurrentProcess(exit_code);

    return core.SyscallResult.success(0);
}
