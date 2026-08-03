const std = @import("std");
const builtin = @import("builtin");

const bit_size = builtin.target.ptrBitWidth();
const AlmostUsize = @Int(.unsigned, bit_size - 1);

pub const fs = @import("fs.zig");
pub const process = @import("process.zig");

pub const SyscallError = enum(AlmostUsize) {
    /// The memory address points to kernel space memory.
    InvalidMemoryAddress = 1,

    /// The path name exceeds the maximum path size.
    PathTooLong = 2,

    /// The provided file descriptor is not valid.
    InvalidFileDescriptor = 3,

    /// There is no file matching the provided path.
    FileNotFound = 4,

    /// There are too many processes running on the system.
    TooManyProcesses = 5,

    /// An allocation failed because the system does not have enough free memory available.
    OutOfMemory = 6,

    /// The ELF file is invalid and cannot be executed.
    InvalidELF = 7,
};

pub const SyscallResult = packed struct(usize) {
    payload: packed union {
        error_number: SyscallError,
        success: AlmostUsize,
    },
    is_error: bool,

    pub fn err(error_number: SyscallError) SyscallResult {
        return .{
            .is_error = true,
            .payload = .{
                .error_number = error_number,
            },
        };
    }

    pub fn success(return_value: AlmostUsize) SyscallResult {
        return .{
            .is_error = false,
            .payload = .{
                .success = return_value,
            },
        };
    }
};

pub const SyscallNumber = enum(usize) {
    exit = 0,
    openat = 1,
    read = 2,
    write = 3,
    spawn = 4,
};
