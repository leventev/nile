const std = @import("std");
const processes = @import("../../../processes.zig");
const syscall_fs = @import("../../../syscall/fs.zig");
const errors = @import("../../../syscall/errors.zig");

pub fn openat(args: [7]u64) !u64 {
    const dirfd: i64 = @bitCast(args[0]);
    const path_ptr_int: u64 = args[1];
    const path_size: u64 = args[2];
    const flags: syscall_fs.OpenFlags = @bitCast(args[3]);
    const mode: syscall_fs.OpenMode = @bitCast(args[4]);

    return syscall_fs.openat(
        dirfd,
        .fromInt(path_ptr_int),
        path_size,
        flags,
        mode,
    );
}

pub fn read(args: [7]u64) !u64 {
    const fd = args[0];
    const buffer = args[1];
    const buffer_size = args[2];

    _ = fd;
    _ = buffer;
    _ = buffer_size;

    return 0;
}
