const std = @import("std");

const riscv64 = @import("riscv64.zig");
const exit = @import("syscalls/exit.zig");
const fs = @import("syscalls/fs.zig");
const errors = @import("../../syscall/errors.zig");
const scheduler = @import("../../scheduler.zig");
const SyscallError = errors.SyscallError;
const CSR = @import("csr.zig").CSR;
const trap = @import("trap.zig");

const Registers = @import("registers.zig").Registers;
const SyscallCallback = *const fn (args: [7]usize) SyscallError!u64;

pub const Syscall = struct {
    name: []const u8,
    callback: SyscallCallback,
};

const syscall_table: []const Syscall = &[_]Syscall{
    .{ .name = "exit", .callback = exit.exit },
    .{ .name = "openat", .callback = fs.openat },
    .{ .name = "read", .callback = fs.read },
    .{ .name = "write", .callback = fs.write },
};

// // TODO: REPLACE THIS
const trap_stack_size = 4 * 4096;
var trap_stack: [trap_stack_size]u8 align(16) = undefined;
var trap_regs: Registers = undefined;

pub fn dispatchSyscall(regs: *Registers) void {
    riscv64.current_trap_stack_bottom = @intFromPtr(&trap_stack) + trap_stack_size;
    const old_sscratch = CSR.sscratch.readAndWrite(@intFromPtr(&trap_regs));
    trap.disableInterrupt(@intFromEnum(trap.InterruptCode.supervisor_software));
    trap.enableInterrupts();
    std.log.debug("enable int", .{});

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

    const result: u64 = syscall.callback(args) catch |err|
        @bitCast(-@as(i64, errors.errorToInt(err)));

    std.log.debug("syscall {s} {any}: return {}", .{ syscall.name, args, result });

    regs.gprs[10] = result;

    // ECALL writes its own address into sepc, not the next instruction's
    // so we have to advance the PC ourselves
    regs.pc += 4;
    std.log.debug("disable int", .{});
    trap.disableInterrupts();
    CSR.sscratch.write(old_sscratch);
}
