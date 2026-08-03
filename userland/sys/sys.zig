const std = @import("std");
pub const core = @import("core");
const riscv64 = @import("riscv64.zig");

pub var stdout_fd: u32 = undefined;

pub fn exit(exit_code: isize) noreturn {
    riscv64.sysExit(exit_code);
}

pub const OpenatError = error{
    FileNotFound,
    InvalidFileDescriptor,
    PathTooLong,
    InvalidMemoryAddress,
    OutOfMemory,
};
pub fn openat(dirfd: i64, path: []const u8, flags: u64, mode: u64) OpenatError!u32 {
    const res = riscv64.sysOpenat(dirfd, path, flags, mode);
    if (res.is_error) {
        return switch (res.payload.error_number) {
            .FileNotFound => OpenatError.FileNotFound,
            .InvalidFileDescriptor => OpenatError.InvalidFileDescriptor,
            .PathTooLong => OpenatError.PathTooLong,
            .InvalidMemoryAddress => OpenatError.InvalidMemoryAddress,
            .OutOfMemory => OpenatError.OutOfMemory,
            else => unreachable,
        };
    }

    return @intCast(res.payload.success);
}

pub const ReadError = error{
    InvalidFileDescriptor,
    InvalidMemoryAddress,
    OutOfMemory,
};
pub fn read(fd: u32, buff: []u8) ReadError!usize {
    const res = riscv64.sysRead(fd, buff);
    if (res.is_error) {
        return switch (res.payload.error_number) {
            .InvalidMemoryAddress => ReadError.InvalidMemoryAddress,
            .OutOfMemory => ReadError.OutOfMemory,
            .InvalidFileDescriptor => ReadError.InvalidFileDescriptor,
            else => unreachable,
        };
    }

    return res.payload.success;
}

pub const WriteError = error{
    InvalidFileDescriptor,
    InvalidMemoryAddress,
    OutOfMemory,
};
pub fn write(fd: u32, buff: []const u8) WriteError!usize {
    const res = riscv64.sysWrite(fd, buff);
    if (res.is_error) {
        return switch (res.payload.error_number) {
            .InvalidMemoryAddress => WriteError.InvalidMemoryAddress,
            .OutOfMemory => WriteError.OutOfMemory,
            .InvalidFileDescriptor => WriteError.InvalidFileDescriptor,
            else => unreachable,
        };
    }

    return res.payload.success;
}

pub const SpawnError = error{
    InvalidFileDescriptor,
    InvalidMemoryAddress,
    OutOfMemory,
    InvalidELF,
};
pub fn spawn(executable_fd: u32, flags: u64) SpawnError!u32 {
    const res = riscv64.sysSpawn(executable_fd, flags);
    if (res.is_error) {
        return switch (res.payload.error_number) {
            .OutOfMemory => SpawnError.OutOfMemory,
            .InvalidFileDescriptor => SpawnError.InvalidFileDescriptor,
            .TooManyProcesses => SpawnError.TooManyProcesses,
            .InvalidELF => SpawnError.InvalidELF,
            else => unreachable,
        };
    }

    return @intCast(res.payload.success);
}

pub const DirectoryEntryFull = struct {
    header: *core.fs.DirectoryEntryHeader,
    name: []u8,
};

pub const DirectoryEntryIterator = struct {
    buff: []u8,

    pub fn next(self: *DirectoryEntryIterator) ?DirectoryEntryFull {
        if (self.buff.len == 0) return null;

        const header_size = @sizeOf(core.fs.DirectoryEntryHeader);

        const header: *core.fs.DirectoryEntryHeader = @ptrCast(@alignCast(self.buff.ptr));
        const name_end = header_size + header.name_size;
        const name_ptr: [*]u8 = @ptrCast(self.buff[header_size..name_end]);
        const name = name_ptr[0..header.name_size];

        const padded_len = std.mem.alignForward(usize, name_end, header_size);
        const next_buffer_start = @min(padded_len, self.buff.len);

        self.buff = self.buff[next_buffer_start..self.buff.len];
        return DirectoryEntryFull{ .header = header, .name = name };
    }
};

pub fn readDirectory(fd: u32, buff: []u8) ReadError!DirectoryEntryIterator {
    const bytes_read = try read(fd, buff);
    return DirectoryEntryIterator{ .buff = buff[0..bytes_read] };
}
