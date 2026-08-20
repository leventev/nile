const std = @import("std");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");

pub const ThreadState = extern struct {
    pub const gpr_count = 32;

    gprs: [gpr_count]u64,
    pc: u64,
    status: trap.SStatus,

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
            kio.kernel_log(log_level, .riscv, "{s}", .{writer.buffered()});
            writer.end = 0;
        }
    }

    pub fn printRegs(self: Self, comptime log_level: std.log.Level) void {
        self.printGPRs(log_level);
        kio.kernel_log(log_level, .riscv, "pc: 0x{x:0>16}", .{self.pc});
        kio.kernel_log(log_level, .riscv, "status: {any}", .{self.status});
    }
};
