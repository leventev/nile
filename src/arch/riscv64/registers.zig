const std = @import("std");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");

const log = std.log.scoped(.riscv64);

pub const ThreadState = extern struct {
    pub const gpr_count = 32;

    gprs: [gpr_count]u64,
    pc: u64,
    status: SStatus,

    const Self = @This();

    pub const zero = 0;
    pub const return_addr = 1;
    pub const stack_ptr = 2;
    pub const global_data_ptr = 3;
    pub const thread_ptr = 4;
    pub const temporary_0 = 5;
    pub const temporary_1 = 6;
    pub const temporary_2 = 7;
    pub const saved_0 = 8;
    pub const frame_ptr = 8;
    pub const saved_1 = 9;
    pub const argument_0 = 10;
    pub const argument_1 = 11;
    pub const argument_2 = 12;
    pub const argument_3 = 13;
    pub const argument_4 = 14;
    pub const argument_5 = 15;
    pub const argument_6 = 16;
    pub const argument_7 = 17;
    pub const saved_2 = 18;
    pub const saved_3 = 19;
    pub const saved_4 = 20;
    pub const saved_5 = 21;
    pub const saved_6 = 22;
    pub const saved_7 = 23;
    pub const saved_8 = 24;
    pub const saved_9 = 25;
    pub const saved_10 = 26;
    pub const saved_11 = 27;
    pub const temporary_3 = 28;
    pub const temporary_4 = 29;
    pub const temporary_5 = 30;
    pub const temporary_6 = 31;

    pub fn printGPR(self: Self, writer: *std.Io.Writer, idx: usize) !void {
        std.debug.assert(idx < gpr_count);

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
        try writer.splatByteAll(' ', rem);
        try writer.print("0x{x:0>16}", .{self.gprs[idx]});
    }

    pub fn printGPRs(self: Self, comptime log_level: std.log.Level) void {
        const logFn = switch (log_level) {
            .debug => log.debug,
            .info => log.info,
            .err => log.err,
            .warn => log.warn,
        };

        const total_regs = 32;
        const regs_per_line = 4;
        const lines = total_regs / regs_per_line;

        var buff: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buff);

        for (0..lines) |i| {
            for (0..regs_per_line) |j| {
                self.printGPR(&writer, i * regs_per_line + j) catch unreachable;
                writer.writeByte(' ') catch unreachable;
            }
            logFn("{s}", .{writer.buffered()});
            writer.end = 0;
        }
    }

    pub fn printRegs(self: Self, comptime log_level: std.log.Level) void {
        self.printGPRs(log_level);
        const logFn = switch (log_level) {
            .debug => log.debug,
            .info => log.info,
            .err => log.err,
            .warn => log.warn,
        };
        logFn("pc: 0x{x:0>16}", .{self.pc});
        logFn("status: {any}", .{self.status});
    }
};

pub const MPP = enum(u2) {
    user = 0b00,
    supervisor = 0b01,
    __reserved = 0b10,
    machine = 0b11,
};

pub const SPP = enum(u1) {
    user = 0,
    supervisor = 1,
};

pub const VectorStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

pub const FloatStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

pub const ExtraExtensionStatus = enum(u2) {
    all_off = 0,
    none_dirt_or_clean = 1,
    none_dirt_some_clean = 2,
    some_dirty = 3,
};

pub const MPRV = enum(u1) {
    normal = 0,
    behave_like_mpp = 1,
};

pub const SUM = enum(u1) {
    prohibited = 0,
    permitted = 1,
};

pub const XLength = enum(u2) {
    x32 = 1,
    x64 = 2,
    x128 = 3,
};

pub const MStatus = packed struct(u64) {
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

pub const SStatus = packed struct(u64) {
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

    pub fn print(self: SStatus, comptime log_level: std.log.Level) void {
        const logFn = switch (log_level) {
            .debug => log.debug,
            .info => log.info,
            .err => log.err,
            .warn => log.warn,
        };

        logFn(
            "Status=[SIE={} SPIE={} UBE={} SPP={} VS={} FS={} XS={} SUM={} MXR={} XLEN={} SD={}]",
            .{
                self.supervisor_interrupt_enable,
                self.supervisor_previous_interrupt_enable,
                self.user_big_endian,
                self.supervisor_previous_privilege,
                self.vector_status,
                self.extra_extension_status,
                self.supervisor_user_memory_accessable,
                self.executable_memory_read,
                self.supervisor_previous_interrupt_enable,
                self.user_xlen,
                self.state_dirty,
            },
        );
    }
};
