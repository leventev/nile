// documentation: https://github.com/riscv-non-isa/riscv-sbi-doc

pub const sbi_base_ext_id = 0x10;
pub const sbi_get_specification_version = 0;
pub const sbi_get_implementation_id = 1;
pub const sbi_get_implementation_version = 2;

pub const sbi_debug_console_ext_id = 0x4442434E;
pub const sbi_debug_con_write = 0;

pub const sbi_timer_ext_id = 0x54494D45;
pub const sbi_timer_set_timer = 0;

pub const sbi_implementations: []const []const u8 = &.{
    "Berkeley Boot Loader (BBL)",
    "OpenSBI",
    "Xvisor",
    "KVM",
    "RustSBI",
    "Diosix",
    "Coffer",
    "Xen Project",
    "PolarFire Hart Software Services",
    "coreboot",
    "oreboot",
    "bhyve",
};

const SBIErrorCode = enum(i64) {
    success = 0,
    err_failed = 1,
    err_not_supported = 2,
    err_invalid_param = 3,
    err_denied = 4,
    err_invalid_addresss = 5,
    err_already_available = 6,
    err_already_started = 7,
    err_already_stopped = 8,
    err_no_shmem = 9,
    err_invalid_state = 10,
    err_bad_range = 11,
};

const SBIError = error{
    Failed,
    NotSupported,
    InvalidParam,
    Denied,
    InvalidAddress,
    AlreadyAvailable,
    AlreadyStarted,
    AlreadyStopped,
    NoSharedMemory,
    InvalidState,
    BadRange,
};

pub fn call(extension: u64, function: u64, arg0: u64, arg1: u64, arg2: u64) SBIError!i64 {
    var val: i64 = undefined;
    var error_code_val: i64 = undefined;
    asm volatile ("ecall"
        : [error_code_val] "={a0}" (error_code_val),
        : [extension] "{a7}" (extension),
          [function] "{a6}" (function),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
    );

    // TODO: https://github.com/ziglang/zig/issues/215 :(
    asm volatile (""
        : [val] "={a1}" (val),
    );

    const error_code: SBIErrorCode = @enumFromInt(error_code_val);

    switch (error_code) {
        .success => return val,
        .err_failed => return error.Failed,
        .err_not_supported => return error.NotSupported,
        .err_invalid_param => return error.InvalidParam,
        .err_denied => return error.Denied,
        .err_invalid_addresss => return error.InvalidAddress,
        .err_already_available => return error.AlreadyAvailable,
        .err_already_started => return error.AlreadyStarted,
        .err_already_stopped => return error.AlreadyStopped,
        .err_no_shmem => return error.NoSharedMemory,
        .err_invalid_state => return error.InvalidState,
        .err_bad_range => return error.BadRange,
    }
}

pub fn debugConsoleWrite(str: []const u8) SBIError!void {
    const addr_int = @intFromPtr(str.ptr);
    _ = try call(sbi_debug_console_ext_id, sbi_debug_con_write, str.len, addr_int, 0);
}

pub fn getSpecificationVersion() u64 {
    const res = call(sbi_base_ext_id, sbi_get_specification_version, 0, 0, 0) catch unreachable;
    return @intCast(res);
}

pub fn getImplementationID() u64 {
    const res = call(sbi_base_ext_id, sbi_get_implementation_id, 0, 0, 0) catch unreachable;
    return @intCast(res);
}

pub fn getImplementationVersion() u64 {
    const res = call(sbi_base_ext_id, sbi_get_implementation_version, 0, 0, 0) catch unreachable;
    return @intCast(res);
}

pub fn setTimer(stime: u64) void {
    _ = call(sbi_timer_ext_id, sbi_timer_set_timer, stime, 0, 0) catch unreachable;
}
