const std = @import("std");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");
const device = @import("device.zig");

/// ID of the thread. Every thread regardless of purpose has a unique ID.
id: Id,

///
scheduler_list_node: std.DoublyLinkedList.Node,

registers: arch.Registers,

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
    user: bool,

    process_list_node: std.DoublyLinkedList.Node,

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
