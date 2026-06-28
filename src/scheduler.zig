const std = @import("std");
const config = @import("config.zig");
const Thread = @import("Thread.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const buddy_allocator = @import("mem/buddy_allocator.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");
const device = @import("device.zig");

const log = std.log.scoped(.scheduler);

const Device = device.Device;

const stack_size_order = 4;
const stack_size = @shlExact(1, stack_size_order) * 4096;

pub var running_threads: std.DoublyLinkedList = .{};
pub var threads_available = std.bit_set.ArrayBitSet(usize, Thread.Id.max).initFull();

var thread_cache: slab_allocator.ObjectCache(Thread) = .{};

pub const Error = error{
    no_available_threads,
    out_of_memory,
};

pub fn queueSoftInterruptHandler(thread: *Thread) void {
    std.debug.assert(thread.purpose == .soft_interrupt);

    if (thread.purpose.soft_interrupt.queued) return;

    arch.setupSoftInterruptThread(thread);

    thread.purpose.soft_interrupt.queued = true;
    appendRunningThread(thread);
}

/// Append a thread at the end of the running threads linked list.
fn appendRunningThread(thread: *Thread) void {
    var node: *?*std.DoublyLinkedList.Node = &running_threads.first;
    while (node.*) |next_ptr| : (node = &next_ptr.next) {
        // check whether a thread is already added

        if (config.debug_scheduler) {
            if (@intFromPtr(next_ptr) == @intFromPtr(&thread.scheduler_list_node)) {
                std.debug.panicExtra(
                    null,
                    "trying to append an already queued thread to running threads list, TID: {}",
                    .{@intFromEnum(thread.id)},
                );
            }
        }
    }

    node.* = &thread.scheduler_list_node;
    thread.scheduler_list_node.next = null;
}

/// Get the lowest available thread ID
fn nextThreadId() Error!Thread.Id {
    const thread_id_int = threads_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(thread_id_int);
}

pub fn newSoftInterruptHandler(
    callback: *const fn (dev: *Device) void,
    dev: *Device,
) Error!*Thread {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;

    thread.purpose = .{
        .soft_interrupt = .{
            .callback = callback,
            .dev = dev,
            .queued = false,
        },
    };

    // TODO: smaller stack size or on demand by the caller
    const stack_bottom = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    const stack_top = stack_bottom.add(stack_size);
    thread.kernel_stack_top = mm.physicalToVirtualAddress(stack_top);
    thread.kernel_stack_size = std.math.shl(usize, 1, 12 + stack_size_order);

    const callback_addr = @intFromPtr(callback);

    if (config.debug_scheduler) {
        std.log.debug("new soft interrupt thread(TID={}), callback: 0x{x}, stack top: 0x{x}, dev: {s}", .{
            thread_id,
            callback_addr,
            stack_top.asInt(),
            dev.name,
        });
    }

    return thread;
}

/// Create a new kernel thread
pub fn newKernelThread(entry_point: *const fn () void, owner_process: *Process) Error!*Thread {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;

    thread.purpose = .{
        .general = .{
            .owner_process = owner_process,
            .user = false,
            .process_list_node = .{},
        },
    };

    owner_process.associated_threads.append(&thread.purpose.general.process_list_node);

    const stack_bottom = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    const stack_top = stack_bottom.add(stack_size);
    thread.kernel_stack_top = mm.physicalToVirtualAddress(stack_top);
    thread.kernel_stack_size = std.math.shl(usize, 1, 12 + stack_size_order);

    const entry_point_addr = @intFromPtr(entry_point);
    arch.setupNewGeneralThread(thread, null, entry_point_addr);
    appendRunningThread(thread);

    if (config.debug_scheduler) {
        std.log.debug("new kernel thread(TID={}), entry point: 0x{x}, stack top: 0x{x}", .{
            thread_id,
            entry_point_addr,
            stack_top.asInt(),
        });
    }

    return thread;
}

/// Create a new user thread
pub fn newUserThread(
    entry_point_addr: usize,
    user_stack_bottom_addr: usize,
    owner_process: *Process,
) Error!*Thread {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;
    const stack_bottom = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    const stack_top = stack_bottom.add(stack_size);
    thread.kernel_stack_top = mm.physicalToVirtualAddress(stack_top);

    thread.purpose = .{
        .general = .{
            .owner_process = owner_process,
            .user = true,
            .process_list_node = .{},
        },
    };

    owner_process.associated_threads.append(&thread.purpose.general.process_list_node);

    arch.setupNewGeneralThread(thread, user_stack_bottom_addr, entry_point_addr);
    appendRunningThread(thread);

    if (config.debug_scheduler) {
        std.log.debug("new user thread(TID={}), entry point: 0x{x}, stack top: 0x{x}", .{
            thread_id,
            entry_point_addr,
            // stack_top_addr,
        });
    }

    return thread;
}

/// Removes a running thread from the running queue.
/// The thread is freed thus the pointer becomes invalid.
/// The function does not schedule the new first thread.
pub fn removeThread(thread: *Thread) void {
    running_threads.remove(&thread.scheduler_list_node);
    thread_cache.free(thread);
}

pub fn dumpRunningThreads() void {
    // TODO: locking here too

    std.log.debug("running threads:", .{});
    var node = running_threads.first;
    while (node) |node_ptr| : (node = node_ptr.next) {
        const thread: *Thread = @fieldParentPtr("scheduler_list_node", node_ptr);
        std.log.debug("{}", .{thread.id});
    }
}

pub fn forceScheduleNextThread() void {
    const prev_thread = popCurrentThread();
    if (prev_thread.purpose == .soft_interrupt) {
        prev_thread.purpose.soft_interrupt.queued = false;
    } else {
        appendRunningThread(prev_thread);
    }

    const next_thread = getCurrentThread();
    arch.forceScheduleNextThread(next_thread);
}

fn scheduleNextThread() void {
    const prev_thread = popCurrentThread();
    if (prev_thread.purpose == .soft_interrupt) {
        prev_thread.purpose.soft_interrupt.queued = false;
    } else {
        appendRunningThread(prev_thread);
    }

    scheduleCurrent();
}

pub fn scheduleCurrent() void {
    const next_thread = getCurrentThread();
    arch.scheduleNextThread(next_thread);
}

pub fn getCurrentThread() *Thread {
    const current_thread_node = running_threads.first orelse @panic("Running threads list is empty, sentinel is not running?");
    const thread: *Thread = @fieldParentPtr("scheduler_list_node", current_thread_node);
    return thread;
}

pub fn popCurrentThread() *Thread {
    const current_thread_node = running_threads.popFirst() orelse @panic("Running threads list is empty, sentinel is not running?");
    const thread: *Thread = @fieldParentPtr("scheduler_list_node", current_thread_node);
    return thread;
}

pub fn tick() void {
    scheduleNextThread();
}

/// Initialize the scheduler.
pub fn init() void {
    thread_cache = slab_allocator.createObjectCache(Thread);
}
