const std = @import("std");
const mm = @import("../mem/mm.zig");
const errors = @import("errors.zig");
const SyscallError = errors.SyscallError;
const fs = @import("../fs.zig");
const processes = @import("../processes.zig");

pub const OpenFlags = packed struct(u64) {
    reserved: u64,
};

pub const OpenMode = packed struct(u64) {
    reserved: u64,
};

const dirfd_cwd = -100;
const path_size_max = 256;

pub fn openat(
    dirfd: isize,
    path_ptr: mm.UserAddress,
    path_size: usize,
    flags: OpenFlags,
    mode: OpenMode,
) SyscallError!usize {
    _ = dirfd;

    if (path_size == 0)
        return SyscallError.file_not_found;

    if (path_size >= path_size_max)
        return SyscallError.path_too_long;

    // last byte accessed
    const path_end_ptr = path_ptr.add(path_size - 1);

    if (!path_ptr.isValid() or !path_end_ptr.isValid())
        return SyscallError.invalid_memory_address;

    const path = path_ptr.asPtr([*]u8)[0..path_size];

    _ = flags;
    _ = mode;

    const current_process = processes.currentProcess();

    const open_file = fs.openFile(
        current_process.mount_table,
        path,
    ) catch return SyscallError.file_not_found;

    // TODO:
    var next_fd: u32 = 0;
    while (current_process.file_descriptor_table[next_fd] != null) : (next_fd += 1) {}

    current_process.file_descriptor_table[next_fd] = open_file;

    return next_fd;
}
