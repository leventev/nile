const std = @import("std");
const mm = @import("../mem/mm.zig");
const errors = @import("errors.zig");
const SyscallError = errors.SyscallError;
const vfs = @import("../vfs.zig");
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

    const path = path_ptr.asPtr([*]const u8)[0..path_size];

    _ = flags;
    _ = mode;

    const current_process = processes.currentProcess();

    const open_file = vfs.openFile(
        current_process.mount_table,
        path,
    ) catch return SyscallError.file_not_found;

    // TODO:
    var next_fd: u32 = 0;
    while (current_process.file_descriptor_table[next_fd] != null) : (next_fd += 1) {}

    current_process.file_descriptor_table[next_fd] = .{
        .file = open_file,
        .offset = 0,
    };

    return next_fd;
}

pub fn read(
    fd: u32,
    buff_ptr: mm.UserAddress,
    buff_size: usize,
) SyscallError!usize {
    if (buff_size == 0)
        return 0;

    // last byte accessed
    const buff_end_ptr = buff_ptr.add(buff_size - 1);

    if (!buff_ptr.isValid() or !buff_end_ptr.isValid())
        return SyscallError.invalid_memory_address;

    const buff = buff_ptr.asPtr([*]u8)[0..buff_size];

    const current_process = processes.currentProcess();

    // TODO:
    std.debug.assert(fd < current_process.file_descriptor_table.len);

    const open_file = current_process.file_descriptor_table[fd] orelse
        return SyscallError.invalid_file_descriptor;

    return open_file.file.read(buff, open_file.offset) catch @panic("TODO");
}

pub fn write(
    fd: u32,
    buff_ptr: mm.UserAddress,
    buff_size: usize,
) SyscallError!usize {
    if (buff_size == 0)
        return 0;

    // last byte accessed
    const buff_end_ptr = buff_ptr.add(buff_size - 1);

    if (!buff_ptr.isValid() or !buff_end_ptr.isValid())
        return SyscallError.invalid_memory_address;

    const buff = buff_ptr.asPtr([*]u8)[0..buff_size];

    const current_process = processes.currentProcess();

    // TODO:
    std.debug.assert(fd < current_process.file_descriptor_table.len);

    const open_file = current_process.file_descriptor_table[fd] orelse
        return SyscallError.invalid_file_descriptor;

    return open_file.file.write(buff, open_file.offset) catch @panic("TODO");
}
