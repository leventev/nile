const std = @import("std");

const riscv64 = @import("riscv64.zig");
const scheduler = @import("../../scheduler.zig");
const core = @import("core");
const CSR = @import("csr.zig").CSR;
const trap = @import("trap.zig");

const exit = @import("syscalls/exit.zig");
const fs = @import("syscalls/fs.zig");
const proc = @import("syscalls/process.zig");

const ThreadState = @import("registers.zig").ThreadState;
const SyscallCallback = *const fn (args: [7]usize) core.SyscallResult;

pub const Syscall = struct {
    name: []const u8,
    callback: SyscallCallback,
};

const syscall_table: []const Syscall = &[_]Syscall{
    .{ .name = "exit", .callback = exit.exit },
    .{ .name = "openat", .callback = fs.openat },
    .{ .name = "read", .callback = fs.read },
    .{ .name = "write", .callback = fs.write },
    .{ .name = "spawn", .callback = proc.spawn },
};

pub fn dispatchSyscall(user_state: *ThreadState) void {
    // interrupts are enabled during syscalls
    // the userspace state of the thread is stored in the user ThreadState
    // the address of the kernel ThreadState is set to sscratch, if an interrupt occurs
    // during a syscall the current thread state is saved to it.
    // while in userspace trap.current_trap_stack_bottom contains the kernel stack of the thread
    // while in a syscall handler trap.current_trap_stack_bottom contains the per-core stack

    // TODO: the current implementation is messy. clean it up

    const current_thread = scheduler.getCurrentThread();
    const current_thread_user = &current_thread.purpose.general.user.?;
    current_thread_user.in_userspace = false;

    const core_trap_stack_bottom = @intFromPtr(&trap.trap_stack) + trap.trap_stack_size;

    CSR.sscratch.write(@intFromPtr(current_thread.kernel_state));
    trap.current_trap_stack_bottom = core_trap_stack_bottom;

    trap.enableInterrupts();

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

    const result: u64 = @bitCast(syscall.callback(args));

    std.log.debug("syscall {s} {any}: return 0x{x}", .{ syscall.name, args, result });

    user_state.gprs[10] = result;

    // ECALL writes its own address into sepc, not the next instruction's
    // so we have to advance the PC ourselves
    user_state.pc += 4;

    current_thread_user.in_userspace = true;

    _ = trap.disableInterrupts();

    // if there was a timer interrupt or the syscall was exit() then scheduleNextThread
    // has already been called and that set sscratch and current_trap_stack_bottom,
    // but in some cases the wrong values are used (e. g. the next thread is the syscall caller,
    // since at the time of the interrupt in_userspace was false the kernel ThreadState
    // and stack are set instead of the user's)

    const next_thread = scheduler.getCurrentThread();
    trap.current_trap_stack_bottom = next_thread.effectiveThreadStackBottom().int;

    // TODO: ?
    if (next_thread.purpose == .general) {
        riscv64.switchAddressSpace(next_thread.purpose.general.owner_process.root_page_table);
    }

    CSR.sscratch.write(@intFromPtr(next_thread.effectiveThreadState()));
}
