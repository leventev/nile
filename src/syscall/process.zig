const std = @import("std");
const mm = @import("../mem/mm.zig");
const errors = @import("errors.zig");
const SyscallError = errors.SyscallError;
const vfs = @import("../vfs.zig");
const processes = @import("../processes.zig");

pub const SpawnFlags = packed struct(u64) {
    reserved: u64,
};

pub fn spawn(
    executable_fd: usize,
    flags: SpawnFlags,
) SyscallError!usize {
    const current_process = processes.currentProcess();

    if (executable_fd >= current_process.file_descriptor_table.len)
        return SyscallError.InvalidFileDescriptor;

    const executable_file = current_process.file_descriptor_table[executable_fd] orelse
        return SyscallError.InvalidFileDescriptor;

    const new_process = try processes.spawnProcess(
        executable_file.file,
        current_process.id,
        current_process.mount_table,
        current_process.root_page_table,
    );

    _ = flags;

    return @intFromEnum(new_process.id);
}
