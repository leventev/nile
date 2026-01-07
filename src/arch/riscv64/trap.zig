const std = @import("std");
const kio = @import("../../kio.zig");
const csr = @import("csr.zig").CSR;
const sbi = @import("sbi.zig");
const timer = @import("timer.zig");
const devicetree = @import("root").devicetree;

extern fn trapHandlerSupervisor() void;

const TrapData = struct {
    gprs: [32]u64,

    const Self = @This();

    fn printGPR(self: Self, writer: anytype, idx: usize) !void {
        std.debug.assert(idx < 32);

        const alternative_names = [_][]const u8{
            "zr", "ra", "sp",  "gp",  "tp", "t0",
            "t1", "t2", "s0",  "s1",  "a0", "a1",
            "a2", "a3", "a4",  "a5",  "a6", "a7",
            "s2", "s3", "s4",  "s5",  "s6", "s7",
            "s8", "s9", "s10", "s11", "t3", "t4",
            "t5", "t6",
        };

        const name = alternative_names[idx];
        var name_total_len = 2 + name.len;
        if (idx > 9) name_total_len += 1;

        const align_to = 7;
        const rem = align_to - name_total_len;

        try writer.print("x{}/{s}", .{ idx, name });
        try writer.writeByteNTimes(' ', rem);
        try writer.print("0x{x:0>16}", .{self.gprs[idx]});
    }

    fn printGPRs(self: Self, comptime log_level: std.log.Level) void {
        const total_regs = 32;
        const regs_per_line = 4;
        const lines = total_regs / regs_per_line;

        var buff: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buff);
        var writer = stream.writer();

        for (0..lines) |i| {
            for (0..regs_per_line) |j| {
                self.printGPR(writer, i * regs_per_line + j) catch unreachable;
                writer.writeByte(' ') catch unreachable;
            }
            kio.kernel_log(log_level, .riscv_trap, "{s}", .{stream.getWritten()});
            stream.reset();
        }
    }
};

// TODO: per hart
var trapFrame = TrapData{
    .gprs = [_]u64{0} ** 32,
};

const TrapVectorBaseAddr = packed struct(u64) {
    mode: Mode,
    base: u62,

    const Mode = enum(u2) {
        direct = 0,
        vectored = 1,
    };
    // 0x80200228
    fn make(addr: u64, mode: Mode) TrapVectorBaseAddr {
        std.debug.assert(addr & 0b11 == 0);
        return .{
            .mode = mode,
            .base = @intCast(
                std.math.shr(
                    u64,
                    addr,
                    2,
                ),
            ),
        };
    }
};

const TrapCause = packed struct(u64) {
    code: u63,
    asynchronous: bool,

    const Self = @This();

    fn exception(self: Self) ExceptionCode {
        std.debug.assert(!self.asynchronous);
        return @enumFromInt(self.code);
    }

    fn interrupt(self: Self) InterruptCode {
        std.debug.assert(self.asynchronous);
        return @enumFromInt(self.code);
    }
};

const ExceptionCode = enum(u63) {
    instruction_address_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_address_misaligned = 4,
    load_access_fault = 5,
    store_or_amo_address_misaligned = 6,
    store_or_amo_access_fault = 7,
    ecall_u_mode = 8,
    ecall_s_mode = 9,
    ecall_m_mode = 11, // read only fix 0
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_or_amo_page_fault = 15,
    software_check = 18,
    hardware_error = 19,
};

pub const InterruptCode = enum(u63) {
    supervisor_software = 1,
    machine_software = 3,
    supervisor_timer = 5,
    machine_timer = 7,
    supervisor_external = 9,
    machine_external = 11,
    counter_overflow = 13,
};

const MPP = enum(u2) {
    user = 0b00,
    supervisor = 0b01,
    __reserved = 0b10,
    machine = 0b11,
};

const SPP = enum(u1) {
    user = 0,
    supervisor = 1,
};

const VectorStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

const FloatStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

const ExtraExtensionStatus = enum(u2) {
    all_off = 0,
    none_dirt_or_clean = 1,
    none_dirt_some_clean = 2,
    some_dirty = 3,
};

const MPRV = enum(u1) {
    normal = 0,
    behave_like_mpp = 1,
};

const SUM = enum(u1) {
    prohibited = 0,
    permitted = 1,
};

const XLength = enum(u2) {
    x32 = 1,
    x64 = 2,
    x128 = 3,
};

const MStatus = packed struct(u64) {
    __reserved1: u1,
    supervisor_interrupt_enable: bool,
    __reserved2: u1,
    machine_interrupt_enable: bool,
    __reserved3: u1,
    supervisor_previous_interrupt_enable: bool,
    user_big_endian: bool,
    machine_previous_interrupt_enable: bool,
    supervisor_previous_privilege: SPP,
    vector_status: VectorStatus,
    machine_previous_privilege: MPP,
    float_status: FloatStatus,
    extra_extension_status: ExtraExtensionStatus,
    memory_privilege: MPRV,
    supervisor_user_memory_accessable: bool,
    executable_memory_read: bool,
    trap_virtual_memory: bool,
    timeout_wait: bool,
    trap_sret: bool,
    __reserved4: u9,
    user_xlen: XLength,
    supervisor_xlen: XLength,
    supervisor_big_endian: bool,
    machine_big_endian: bool,
    __reserved5: u25,
    state_dirty: bool,
};

const SStatus = packed struct(u64) {
    __reserved1: u1,
    supervisor_interrupt_enable: bool,
    __reserved2: u3,
    supervisor_previous_interrupt_enable: bool,
    user_big_endian: bool,
    __reserved3: u1,
    supervisor_previous_privilege: SPP,
    vector_status: VectorStatus,
    __reserved4: u2,
    float_status: FloatStatus,
    extra_extension_status: ExtraExtensionStatus,
    __reserved5: u1,
    supervisor_user_memory_accessable: bool,
    executable_memory_read: bool,
    __reserved6: u12,
    user_xlen: XLength,
    __reserved7: u29,
    state_dirty: bool,

    const Self = @This();

    fn print(self: Self, comptime log_level: std.log.Level) void {
        kio.kernel_log(log_level, .riscv_trap, "SIE={} SPIE={} SPP={s}", .{
            self.supervisor_interrupt_enable,
            self.supervisor_previous_interrupt_enable,
            @tagName(self.supervisor_previous_privilege),
        });

        kio.kernel_log(log_level, .riscv_trap, "VS={s} FS={s} XS={s} SD={}", .{
            @tagName(self.vector_status),
            @tagName(self.float_status),
            @tagName(self.extra_extension_status),
            self.state_dirty,
        });

        kio.kernel_log(log_level, .riscv_trap, "SUM={} MXR={} UXL={} UBE={}", .{
            self.supervisor_user_memory_accessable,
            self.executable_memory_read,
            self.supervisor_user_memory_accessable,
            self.user_big_endian,
        });
    }
};

pub fn enableInterrupts() void {
    csr.sstatus.setBits(1 << @bitOffsetOf(SStatus, "supervisor_interrupt_enable"));
}

pub fn disableInterrupts() void {
    csr.sstatus.clearBits(1 << @bitOffsetOf(SStatus, "supervisor_interrupt_enable"));
}

pub fn enableInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    csr.sie.setBits(std.math.shl(u64, 1, id));
}

pub fn disableInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    csr.sie.clearBits(std.math.shl(u64, 1, id));
}

pub fn clearPendingInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    csr.sip.clearBits(std.math.shl(u64, 1, id));
}

fn genericExceptionHandler(code: ExceptionCode, pc: u64, status: SStatus, tval: u64, frame: *TrapData) void {
    status.print(.err);
    frame.printGPRs(.err);
    std.log.err("PC=0x{x}", .{pc});
    std.log.err("Trap value: 0x{x}", .{tval});
    @panic(@tagName(code));
}

fn handleException(code: ExceptionCode, pc: u64, status: SStatus, tval: u64, frame: *TrapData) void {
    switch (code) {
        .load_page_fault, .instruction_page_fault, .store_or_amo_page_fault => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            std.log.err("Faulting address: 0x{x}", .{tval});
            @panic("Page fault");
        },
        .ecall_u_mode => {
            @panic("TODO");
        },
        .ecall_s_mode => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            std.log.err("Trap value: 0x{x}", .{tval});
            @panic("Environment call from S mode");
        },
        .ecall_m_mode => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            std.log.err("Trap value: 0x{x}", .{tval});
            @panic("Environment call from M mode");
        },
        else => genericExceptionHandler(code, pc, status, tval, frame),
    }
}

fn handleInterrupt(code: InterruptCode, pc: u64, status: SStatus, tval: u64, frame: *TrapData) void {
    _ = tval;
    switch (code) {
        .supervisor_software => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Supervisor software interrupt");
        },
        .machine_software => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Machine software interrupt");
        },
        .supervisor_timer => {
            timer.tick();
        },
        .machine_timer => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Machine timer interrupt");
        },
        .supervisor_external => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Supervisor external interrupt");
        },
        .machine_external => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Machine external interrupt");
        },
        .counter_overflow => {
            status.print(.err);
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Counter overflow interrupt");
        },
    }
}

export fn handleTrap(
    epc: u64,
    cause: TrapCause,
    status: SStatus,
    tval: u64,
    frame: *TrapData,
) void {
    if (cause.asynchronous) {
        handleInterrupt(cause.interrupt(), epc, status, tval, frame);
    } else {
        handleException(cause.exception(), epc, status, tval, frame);
    }
}

pub fn initDriver(dt: *const devicetree.DeviceTree, handle: usize) !void {
    _ = dt;
    _ = handle;
    const stvec = TrapVectorBaseAddr.make(
        @intFromPtr(&trapHandlerSupervisor),
        TrapVectorBaseAddr.Mode.direct,
    );

    csr.stvec.write(@bitCast(stvec));
    csr.sscratch.write(@intFromPtr(&trapFrame));
}
