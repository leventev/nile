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
        return SyscallError.invalid_file_descriptor;

    _ = flags;

    return 0;
}
