pub const SyscallError = error{
    /// The memory address points to kernel space memory.
    InvalidMemoryAddress,

    /// The path name exceeds the maximum path size.
    PathTooLong,

    /// The provided file descriptor is not valid.
    InvalidFileDescriptor,

    /// There is no file matching the provided path.
    FileNotFound,

    /// There are too many processes running on the system.
    TooManyProcesses,

    /// An allocation failed because the system does not have enough free memory available.
    OutOfMemory,

    /// The ELF file is invalid and cannot be executed.
    InvalidELF,
};

pub fn errorToInt(err: SyscallError) u32 {
    return switch (err) {
        error.InvalidMemoryAddress => 1,
        error.PathTooLong => 2,
        error.InvalidFileDescriptor => 3,
        error.FileNotFound => 4,
        error.TooManyProcesses => 5,
        error.OutOfMemory => 6,
        error.InvalidELF => 7,
    };
}
