const std = @import("std");

pub fn exit(args: [7]u64) u64 {
    std.log.debug("exit called! {any}", .{args});
    return 123;
}
