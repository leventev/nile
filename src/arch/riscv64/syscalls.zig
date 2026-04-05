const std = @import("std");

const exit = @import("syscalls/exit.zig");

const Registers = @import("registers.zig").Registers;
const SyscallCallback = *const fn (args: [7]usize) u64;

pub const Syscall = struct {
    name: []const u8,
    callback: SyscallCallback,
};

const syscall_table: []const Syscall = &[_]Syscall{
    .{ .name = "exit", .callback = exit.exit },
};

pub fn dispatchSyscall(regs: *Registers) void {
    // a0 starts from index 10 but TODO: make enum for this
    const syscall_num = regs.gprs[10];
    const args: [7]u64 = .{
        regs.gprs[11],
        regs.gprs[12],
        regs.gprs[13],
        regs.gprs[14],
        regs.gprs[15],
        regs.gprs[16],
        regs.gprs[17],
    };

    // ignore invalid syscalls
    if (syscall_num >= syscall_table.len) return;

    const syscall = syscall_table[syscall_num];

    const result = syscall.callback(args);
    regs.gprs[10] = result;

    // ECALL writes its own address into sepc, not the next instruction's
    // so we have to advance the PC ourselves
    regs.pc += 4;
}
