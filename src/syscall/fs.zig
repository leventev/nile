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
    path_ptr_raw: mm.VirtualAddress,
    path_size: usize,
    flags: OpenFlags,
    mode: OpenMode,
) SyscallError!usize {
    _ = dirfd;

    if (path_size == 0)
        return SyscallError.FileNotFound;

    if (path_size >= path_size_max)
        return SyscallError.PathTooLong;

    const path_ptr = mm.UserAddress.fromVirtual(path_ptr_raw) orelse
        return error.InvalidMemoryAddress;
    const path = path_ptr.slice(path_size) orelse return error.InvalidMemoryAddress;

    _ = flags;
    _ = mode;

    const current_process = processes.currentProcess();
    const open_file = vfs.openFile(
        current_process.mount_table,
        path,
    ) catch return SyscallError.FileNotFound;

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
    buff_ptr_raw: mm.VirtualAddress,
    buff_size: usize,
) SyscallError!usize {
    if (buff_size == 0)
        return 0;

    const buff_ptr = mm.UserAddress.fromVirtual(buff_ptr_raw) orelse
        return error.InvalidMemoryAddress;
    const buff = buff_ptr.slice(buff_size) orelse return error.InvalidMemoryAddress;

    const current_process = processes.currentProcess();

    if (fd >= current_process.file_descriptor_table.len)
        return SyscallError.InvalidFileDescriptor;

    const open_file = current_process.file_descriptor_table[fd] orelse
        return SyscallError.InvalidFileDescriptor;

    return open_file.file.read(buff, open_file.offset) catch @panic("TODO");
}

pub fn write(
    fd: u32,
    buff_ptr_raw: mm.VirtualAddress,
    buff_size: usize,
) SyscallError!usize {
    if (buff_size == 0)
        return 0;

    const buff_ptr = mm.UserAddress.fromVirtual(buff_ptr_raw) orelse
        return error.InvalidMemoryAddress;
    const buff = buff_ptr.slice(buff_size) orelse return error.InvalidMemoryAddress;

    const current_process = processes.currentProcess();

    if (fd >= current_process.file_descriptor_table.len)
        return SyscallError.InvalidFileDescriptor;

    const open_file = &(current_process.file_descriptor_table[fd] orelse
        return SyscallError.InvalidFileDescriptor);

    const written = open_file.file.write(buff, open_file.offset) catch @panic("TODO");

    open_file.offset += written;

    return written;
}
