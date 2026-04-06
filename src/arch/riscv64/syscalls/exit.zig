const std = @import("std");
const processes = @import("../../../processes.zig");

pub fn exit(args: [7]u64) u64 {
    std.log.debug("exit called! {any}", .{args});
    processes.killCurrentProcess();
    return 123;
}
