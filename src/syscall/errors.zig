pub const SyscallError = error{
    /// The memory address points to kernel space memory.
    invalid_memory_address,

    /// The path name exceeds the maximum path size.
    path_too_long,

    /// The provided file descriptor is not valid.
    invalid_file_descriptor,

    /// There is no file matching the provided path.
    file_not_found,

    /// There are too many processes running on the system.
    too_many_processes,

    /// An allocation failed because the system does not have enough free memory available.
    out_of_memory,
};

pub fn errorToInt(err: SyscallError) u32 {
    return switch (err) {
        error.invalid_memory_address => 1,
        error.path_too_long => 2,
        error.invalid_file_descriptor => 3,
        error.file_not_found => 4,
        error.too_many_processes => 5,
        error.out_of_memory => 6,
    };
}
