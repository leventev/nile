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
    user: ?struct {
        in_userspace: bool,
        state: *arch.ThreadState,
    },

    process_list_next: ?*Thread,

    /// Which process the thread belongs to.
    owner_process: *Process,
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
        .general => |general| if (general.user) |user|
            if (user.in_userspace)
                user.state
            else
                self.kernel_state
        else
            self.kernel_state,
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
        .general => |general| if (general.user) |user|
            if (user.in_userspace)
                kernel_stack_bottom
            else
                per_cpu_stack_bottom
        else
            per_cpu_stack_bottom,
    };
}
