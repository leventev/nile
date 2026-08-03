const std = @import("std");
const core = @import("core");
const processes = @import("../../../processes.zig");
const syscall_fs = @import("../../../syscall/fs.zig");

pub fn openat(args: [7]u64) core.SyscallResult {
    const dirfd: i64 = @bitCast(args[0]);
    const path_ptr_int: u64 = args[1];
    const path_size: u64 = args[2];
    const flags: core.fs.OpenFlags = @bitCast(args[3]);
    const mode: core.fs.OpenMode = @bitCast(args[4]);

    return syscall_fs.openat(
        dirfd,
        .fromInt(path_ptr_int),
        path_size,
        flags,
        mode,
    );
}

pub fn read(args: [7]u64) core.SyscallResult {
    const fd: u32 = @truncate(args[0]);
    const buffer: u64 = args[1];
    const buffer_size = args[2];

    const res = syscall_fs.read(fd, .fromInt(buffer), buffer_size);

    return res;
}

pub fn write(args: [7]u64) core.SyscallResult {
    const fd: u32 = @truncate(args[0]);
    const buffer: u64 = args[1];
    const buffer_size = args[2];

    return syscall_fs.write(fd, .fromInt(buffer), buffer_size);
}
