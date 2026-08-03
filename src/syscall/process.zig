const std = @import("std");
const core = @import("core");
const mm = @import("../mem/mm.zig");
const vfs = @import("../vfs.zig");
const processes = @import("../processes.zig");

pub fn spawn(
    executable_fd: usize,
    flags: core.process.SpawnFlags,
) core.SyscallResult {
    const current_process = processes.currentProcess();

    if (executable_fd >= current_process.file_descriptor_table.len)
        return .err(.InvalidFileDescriptor);

    const executable_file = current_process.file_descriptor_table[executable_fd] orelse
        return .err(.InvalidFileDescriptor);

    const new_process = processes.spawnProcess(
        executable_file.file,
        current_process.id,
        current_process.mount_table,
        current_process.root_page_table,
    ) catch @panic("TODO");

    _ = flags;

    return .success(@intFromEnum(new_process.id));
}
