pub const SyscallError = error{
    /// The memory address points to kernel space memory.
    invalid_memory_address,

    /// The path name exceeds the maximum path size.
    path_too_long,

    /// The provided file descriptor is not valid.
    invalid_file_descriptor,

    /// There is no file matching the provided path.
    file_not_found,
};

pub fn errorToInt(err: SyscallError) u32 {
    return switch (err) {
        error.invalid_memory_address => 1,
        error.path_too_long => 2,
        error.invalid_file_descriptor => 3,
        error.file_not_found => 4,
    };
}
