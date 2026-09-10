const std = @import("std");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");
const device = @import("device.zig");

const Thread = @This();

/// ID of the thread. Every thread regardless of purpose has a unique ID.
id: Id,

///
scheduler_list_next: ?*Thread,

kernel_state: *arch.ThreadState,

/// Start of the kernel stack
kernel_stack_top: mm.VirtualAddress,

kernel_stack_size: usize,

/// The type/purpose of the thread.
purpose: Purpose,

pub const Id = enum(usize) {
    _,
    pub const max = 8192;
};

pub const Purpose = union(enum) {
    /// General purpose thread.
    general: General,

    /// A soft interrupt handler is scheduled by the actual interrupt handler.
    soft_interrupt: SoftInterruptHandler,
};

pub const General = struct {
    /// Whether the thread is a user or kernel thread.
    user: ?UserThread,

    process_list_next: ?*Thread,

    /// Which process the thread belongs to.
    owner_process: *Process,

    previous_state: ?State,
    current_state: State,

    pub const UserThread = struct {
        thread_state: *arch.ThreadState,
    };

    ///
    ///             exception
    ///           /
    /// userspace - kernelspace - interrupt - exception
    ///           |             \
    ///           |              exception
    ///           \
    ///            interrupt - exception
    ///
    pub const State = enum(u3) {
        /// Thread is running in user space. Only valid for user threads.
        userspace = 0,

        /// Thread is running in kernel space. In case of user threads this means syscall.
        kernelspace = 1,

        /// The thread got interrupted and is executing inside an interrupt handler.
        interrupt = 2,

        /// The thread cause an exception and is executing inside an exception handler.
        exception = 3,
    };
};

pub const SoftInterruptHandler = struct {
    dev: *device.Device,
    callback: *const fn (dev: *device.Device) void,

    /// Whether the thread is already queued. Since a driver or drivers could try to queue
    /// the soft interrupt handler multiple times we would need to traverse the running threads
    /// to avoid adding it to the list again.
    queued: bool,
};

pub fn effectiveThreadState(self: *Thread) *arch.ThreadState {
    return switch (self.purpose) {
        .soft_interrupt => self.kernel_state,

        // TODO: maybe not?
        // if there is a previous state then we are going to switch to that.
        // but if there is no previous state then we are going to continue running
        // in the current state
        .general => |general| switch (general.previous_state orelse general.current_state) {
            .userspace => blk: {
                const user_thread = general.user orelse return self.kernel_state;
                break :blk user_thread.thread_state;
            },
            .kernelspace => self.kernel_state,
            .interrupt, .exception => unreachable,
        },
    };
}

// TODO:
const trap = @import("arch/riscv64/trap.zig");
pub fn effectiveThreadStackBottom(self: *Thread) mm.VirtualAddress {
    const kernel_stack_bottom = self.kernel_stack_top.add(self.kernel_stack_size);
    const per_cpu_stack_top = mm.VirtualAddress.fromInt(@intFromPtr(&trap.trap_stack));
    const per_cpu_stack_bottom = per_cpu_stack_top.add(trap.trap_stack_size);

    return switch (self.purpose) {
        .soft_interrupt => per_cpu_stack_bottom,

        // TODO: maybe not?
        // if there is a previous state then we are going to switch to that.
        // but if there is no previous state then we are going to continue running
        // in the current state
        .general => |general| switch (general.previous_state orelse general.current_state) {
            .userspace => kernel_stack_bottom,
            .kernelspace => per_cpu_stack_bottom,
            .interrupt, .exception => unreachable,
            // TODO: ^^^ set stack for exceptions during interrupts
        },
    };
}
