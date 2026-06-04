const std = @import("std");
const processes = @import("../../../processes.zig");

pub fn openat(args: [7]u64) u64 {
    const dirfd = args[0];
    const path = args[1];
    const flags = args[2];
    const mode = args[3];

    _ = dirfd;
    _ = path;
    _ = flags;
    _ = mode;

    return 0;
}

pub fn read(args: [7]u64) u64 {
    const fd = args[0];
    const buffer = args[1];
    const buffer_size = args[2];

    _ = fd;
    _ = buffer;
    _ = buffer_size;

    return 0;
}
