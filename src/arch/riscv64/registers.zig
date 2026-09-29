const std = @import("std");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");

const log = std.log.scoped(.riscv64);

pub const ThreadState = extern struct {
    /// The number of general purpose registers.
    pub const gpr_count = 32;

    /// The number of general purpose registers excluding x0, which is always 0.
    pub const saved_gpr_count = gpr_count - 1;

    /// General purpose registers excluding x0, which is always 0.
    gprs: [saved_gpr_count]u64,

    sscratch: u64,

    /// Current program counter.
    pc: u64,

    /// Supervisor status.
    status: SStatus,

    /// Trap value
    trap_value: u64,

    /// Trap cause
    trap_cause: u64,

    pub const return_addr = 0;
    pub const stack_ptr = 1;
    pub const global_data_ptr = 2;
    pub const thread_ptr = 3;
    pub const temporary_0 = 4;
    pub const temporary_1 = 5;
    pub const temporary_2 = 6;
    pub const saved_0 = 7;
    pub const frame_ptr = 7;
    pub const saved_1 = 8;
    pub const argument_0 = 9;
    pub const argument_1 = 10;
    pub const argument_2 = 11;
    pub const argument_3 = 12;
    pub const argument_4 = 13;
    pub const argument_5 = 14;
    pub const argument_6 = 15;
    pub const argument_7 = 16;
    pub const saved_2 = 17;
    pub const saved_3 = 18;
    pub const saved_4 = 19;
    pub const saved_5 = 20;
    pub const saved_6 = 21;
    pub const saved_7 = 22;
    pub const saved_8 = 23;
    pub const saved_9 = 24;
    pub const saved_10 = 25;
    pub const saved_11 = 26;
    pub const temporary_3 = 27;
    pub const temporary_4 = 28;
    pub const temporary_5 = 29;
    pub const temporary_6 = 30;

    /// Alternative names of the registers excluding x0.
    const saved_alternative_names = [_][]const u8{
        "ra",  "sp",  "gp", "tp", "t0",
        "t1",  "t2",  "s0", "s1", "a0",
        "a1",  "a2",  "a3", "a4", "a5",
        "a6",  "a7",  "s2", "s3", "s4",
        "s5",  "s6",  "s7", "s8", "s9",
        "s10", "s11", "t3", "t4", "t5",
        "t6",
    };

    /// Alternative names of the registers.
    const alternative_names = [_][]const u8{"zr"} ++ saved_alternative_names;

    pub fn printGPR(writer: *std.Io.Writer, idx: usize, value: usize) !void {
        std.debug.assert(idx < gpr_count);

        const name = alternative_names[idx];
        var name_total_len = 2 + name.len;
        if (idx > 9) name_total_len += 1;

        const align_to = 7;
        const rem = align_to - name_total_len;

        try writer.print("x{}/{s}", .{ idx, name });
        try writer.splatByteAll(' ', rem);
        try writer.print("0x{x:0>16}", .{value});
    }

    pub fn printGPRs(self: ThreadState, comptime log_level: std.log.Level) void {
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

        for (0..lines) |row| {
            for (0..regs_per_line) |col| {
                const idx = row * regs_per_line + col;
                const value = if (idx == 0) 0 else self.gprs[idx - 1];
                printGPR(&writer, idx, value) catch unreachable;
                writer.writeByte(' ') catch unreachable;
            }
            logFn("{s}", .{writer.buffered()});
            writer.end = 0;
        }
    }

    pub fn printRegs(self: ThreadState, comptime log_level: std.log.Level) void {
        self.printGPRs(log_level);
        const logFn = switch (log_level) {
            .debug => log.debug,
            .info => log.info,
            .err => log.err,
            .warn => log.warn,
        };
        logFn("pc: 0x{x:0>16}", .{self.pc});
        self.status.print(log_level);
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
    invalid = 0,
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
