const std = @import("std");
const mm = @import("../mem/mm.zig");
const core = @import("core");
const vfs = @import("../vfs.zig");
const processes = @import("../processes.zig");

const dirfd_cwd = -100;
const path_size_max = 256;

pub fn openat(
    dirfd: isize,
    path_ptr_raw: mm.VirtualAddress,
    path_size: usize,
    flags: core.fs.OpenFlags,
    mode: core.fs.OpenMode,
) core.SyscallResult {
    if (path_size == 0)
        return .err(.FileNotFound);

    if (path_size >= path_size_max)
        return .err(.PathTooLong);

    const path_ptr = mm.UserAddress.fromVirtual(path_ptr_raw) orelse
        return .err(.InvalidMemoryAddress);
    const path = path_ptr.slice(path_size) orelse return .err(.InvalidMemoryAddress);

    _ = flags;
    _ = mode;

    const current_process = processes.currentProcess();

    const start_dir = if (dirfd == dirfd_cwd) unreachable else if (dirfd > 0) blk: {
        const fd: u32 = @intCast(dirfd);
        if (fd >= current_process.file_descriptor_table.len) return .err(.InvalidFileDescriptor);
        const file = current_process.file_descriptor_table[fd] orelse return .err(.InvalidFileDescriptor);

        break :blk file.file;
    } else null;

    const open_file = vfs.openFile(
        current_process.mount_table,
        start_dir,
        path,
    ) catch return .err(.FileNotFound);

    // TODO:
    var next_fd: u32 = 0;
    while (current_process.file_descriptor_table[next_fd] != null) : (next_fd += 1) {}

    current_process.file_descriptor_table[next_fd] = .{
        .file = open_file,
        .offset = 0,
    };

    return .success(next_fd);
}

pub fn read(
    fd: u32,
    buff_ptr_raw: mm.VirtualAddress,
    buff_size: usize,
) core.SyscallResult {
    if (buff_size == 0)
        return .success(0);

    const buff_ptr = mm.UserAddress.fromVirtual(buff_ptr_raw) orelse
        return .err(.InvalidMemoryAddress);
    const buff = buff_ptr.slice(buff_size) orelse return .err(.InvalidMemoryAddress);

    const current_process = processes.currentProcess();

    if (fd >= current_process.file_descriptor_table.len)
        return .err(.InvalidFileDescriptor);

    const open_file = &(current_process.file_descriptor_table[fd] orelse
        return .err(.InvalidFileDescriptor));
    const res = open_file.file.read(buff, &open_file.offset) catch |err| return switch (err) {
        error.OutOfMemory => .err(.OutOfMemory),
        error.InvalidMemoryAddress => .err(.InvalidMemoryAddress),
    };
    return .success(@intCast(res));
}

pub fn write(
    fd: u32,
    buff_ptr_raw: mm.VirtualAddress,
    buff_size: usize,
) core.SyscallResult {
    if (buff_size == 0)
        return .success(0);

    const buff_ptr = mm.UserAddress.fromVirtual(buff_ptr_raw) orelse
        return .err(.InvalidMemoryAddress);
    const buff = buff_ptr.slice(buff_size) orelse return .err(.InvalidMemoryAddress);

    const current_process = processes.currentProcess();

    if (fd >= current_process.file_descriptor_table.len)
        return .err(.InvalidFileDescriptor);

    const open_file = &(current_process.file_descriptor_table[fd] orelse
        return .err(.InvalidFileDescriptor));

    const written = open_file.file.write(buff, open_file.offset) catch @panic("TODO");

    open_file.offset += written;

    return .success(@intCast(written));
}
