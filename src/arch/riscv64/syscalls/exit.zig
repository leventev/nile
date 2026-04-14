const std = @import("std");
const processes = @import("../../../processes.zig");

pub fn exit(args: [7]u64) u64 {
    const exit_code = args[0];
    processes.killCurrentProcess(exit_code);

    return 0;
}
