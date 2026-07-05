const std = @import("std");

const riscv64 = @import("riscv64.zig");
const exit = @import("syscalls/exit.zig");
const fs = @import("syscalls/fs.zig");
const errors = @import("../../syscall/errors.zig");
const scheduler = @import("../../scheduler.zig");
const SyscallError = errors.SyscallError;
const CSR = @import("csr.zig").CSR;
const trap = @import("trap.zig");

const ThreadState = @import("registers.zig").ThreadState;
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

pub fn dispatchSyscall(user_state: *ThreadState) void {
    // interrupts are enabled during syscalls
    // the userspace state of the thread is stored in the user ThreadState
    // the kernel ThreadState is set to sscratch, if an interrupt occurs during a syscall
    // the current thread state is saved to it.
    // while in userspace trap.current_trap_stack_bottom contains the kernel stack of the thread
    // while in a syscall handler trap.current_trap_stack_bottom contains the per-core stack

    // TODO: the current implementation is messy. clean it up

    const current_thread = scheduler.getCurrentThread();
    current_thread.purpose.general.user.?.in_userspace = true;

    const core_trap_stack_bottom = @intFromPtr(&trap.trap_stack) + trap.trap_stack_size;
    std.log.debug("syscall regs: 0x{x}", .{@intFromPtr(user_state)});
    std.log.debug("syscall {}", .{user_state.gprs[10]});

    trap.current_trap_stack_bottom = core_trap_stack_bottom;
    CSR.sscratch.write(@intFromPtr(current_thread.kernel_state));
    std.log.debug("kernel_state: 0x{x} trap bottom: 0x{x}", .{ @intFromPtr(current_thread.kernel_state), core_trap_stack_bottom });

    // std.log.debug("trap sscatch 0x{x} old sccratch: 0x{x}", .{ @intFromPtr(&trap.trap_regs), old_sscratch });
    trap.disableInterrupt(@intFromEnum(trap.InterruptCode.supervisor_software));
    trap.enableInterrupts();
    std.log.debug("enable int", .{});

    // a0 starts from index 10 but TODO: make enum for this
    const syscall_num = user_state.gprs[10];
    const args: [7]u64 = .{
        user_state.gprs[11],
        user_state.gprs[12],
        user_state.gprs[13],
        user_state.gprs[14],
        user_state.gprs[15],
        user_state.gprs[16],
        user_state.gprs[17],
    };

    // ignore invalid syscalls
    if (syscall_num >= syscall_table.len) return;

    const syscall = syscall_table[syscall_num];
    std.log.debug("syscall {s}", .{syscall.name});

    const result: u64 = syscall.callback(args) catch |err|
        @bitCast(-@as(i64, errors.errorToInt(err)));

    std.log.debug("syscall {s} {any}: return {}", .{ syscall.name, args, result });

    user_state.gprs[10] = result;

    // ECALL writes its own address into sepc, not the next instruction's
    // so we have to advance the PC ourselves

    user_state.pc += 4;
    current_thread.purpose.general.user.?.in_userspace = false;

    std.log.debug("disable int", .{});
    _ = trap.disableInterrupts();

    const next_thread = scheduler.getCurrentThread();
    const kernel_stack_bottom = next_thread.kernel_stack_top.add(next_thread.kernel_stack_size).asInt();
    trap.current_trap_stack_bottom = switch (next_thread.purpose) {
        .soft_interrupt => kernel_stack_bottom,
        .general => |general| if (general.user) |_| core_trap_stack_bottom else kernel_stack_bottom,
    };

    CSR.sscratch.write(@intFromPtr(next_thread.effectiveThreadState()));
}
