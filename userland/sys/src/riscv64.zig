const SyscallNumber = enum(u64) {
    exit = 0,
    openat = 1,
    read = 2,
};

pub fn syscall(
    num: SyscallNumber,
    args: anytype,
) i64 {
    if (args.len > 7) @compileError("Too many arguments");

    var return_value_0: i64 = undefined;
    var return_value_1: i64 = undefined;
    switch (args.len) {
        0 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
        ),

        1 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
        ),
        2 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
              [arg1] "{a2}" (args[1]),
        ),
        3 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
              [arg1] "{a2}" (args[1]),
              [arg2] "{a3}" (args[2]),
        ),
        4 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
              [arg1] "{a2}" (args[1]),
              [arg2] "{a3}" (args[2]),
              [arg3] "{a4}" (args[3]),
        ),
        5 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
              [arg1] "{a2}" (args[1]),
              [arg2] "{a3}" (args[2]),
              [arg3] "{a4}" (args[3]),
              [arg4] "{a5}" (args[4]),
        ),
        6 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
              [arg1] "{a2}" (args[1]),
              [arg2] "{a3}" (args[2]),
              [arg3] "{a4}" (args[3]),
              [arg4] "{a5}" (args[4]),
              [arg5] "{a6}" (args[5]),
        ),
        7 => asm volatile ("ecall"
            : [return_value_0] "={a0}" (return_value_0),
              [return_value_1] "={a1}" (return_value_1),
            : [syscall_num] "{a0}" (num),
              [arg0] "{a1}" (args[0]),
              [arg1] "{a2}" (args[1]),
              [arg2] "{a3}" (args[2]),
              [arg3] "{a4}" (args[3]),
              [arg4] "{a5}" (args[4]),
              [arg5] "{a6}" (args[5]),
              [arg6] "{a7}" (args[6]),
        ),
        else => @compileError("Too many arguments"),
    }

    return return_value_0;
}

pub fn sysExit(exit_code: u64) noreturn {
    _ = syscall(.exit, .{exit_code});
    unreachable;
}

pub fn sysOpenat(dirfd: i64, path: []const u8, flags: u64, mode: u64) i64 {
    return syscall(.openat, .{
        @as(u64, @bitCast(dirfd)),
        @intFromPtr(path.ptr),
        path.len,
        flags,
        mode,
    });
}
