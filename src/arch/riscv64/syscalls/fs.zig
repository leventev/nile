const std = @import("std");
const processes = @import("../../../processes.zig");

const OpenFlags = packed struct(u64) {
    reserved: u64,
};

const OpenMode = packed struct(u64) {
    reserved: u64,
};

const dirfd_cwd = -100;

pub fn openat(args: [7]u64) u64 {
    const dirfd: i64 = @intCast(args[0]);
    const path: [*]const u8 = @ptrFromInt(args[1]);
    // const path_size: u64 = args[2];
    // const flags: OpenFlags = args[3];
    // const mode: OpenMode = args[4];

    // TODO: error
    std.debug.assert(dirfd > 0 or dirfd_cwd == -100);

    _ = path;
    // _ = flags;
    // _ = mode;

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
