const std = @import("std");
const config = @import("config.zig");
const Thread = @import("Thread.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const buddy_allocator = @import("mem/buddy_allocator.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");
const device = @import("device.zig");
const sync = @import("sync.zig");

const log = std.log.scoped(.scheduler);

const Device = device.Device;

const stack_size_order = 4;
const stack_size = @shlExact(1, stack_size_order) * 4096;

pub var scheduler_lock: sync.Spinlock = .unlocked;
pub var running_threads: ?*Thread = null;
pub var threads_available = std.bit_set.ArrayBitSet(usize, Thread.Id.max).initFull();

var thread_cache: slab_allocator.ObjectCache(Thread) = .{};
var thread_state_cache: slab_allocator.ObjectCache(arch.ThreadState) = .{};

pub const Error = error{
    no_available_threads,
    out_of_memory,
};

pub fn queueSoftInterruptHandler(thread: *Thread) void {
    const interrupts_enabled = scheduler_lock.lockInterrupt();
    defer scheduler_lock.unlockInterrupt(interrupts_enabled);

    std.debug.assert(thread.purpose == .soft_interrupt);

    if (thread.purpose.soft_interrupt.state == .queued) return;

    arch.setupSoftInterruptThread(thread);

    thread.purpose.soft_interrupt.state = .queued;
    appendRunningThreadLocked(thread);
}

/// Append a thread at the end of the running threads linked list.
fn appendRunningThreadLocked(thread: *Thread) void {
    var next_ptr = &running_threads;
    while (next_ptr.*) |added_thread| : (next_ptr = &added_thread.scheduler_list_next) {
        // check whether a thread is already added
        if (config.debug_scheduler) {
            if (@intFromPtr(added_thread) == @intFromPtr(thread)) {
                std.debug.panicExtra(
                    null,
                    "trying to append an already queued thread to running threads list, TID: {}",
                    .{@intFromEnum(added_thread.id)},
                );
            }
        }
    }

    next_ptr.* = thread;
    thread.scheduler_list_next = null;
}

/// Get the lowest available thread ID
fn nextThreadIdLocked() Error!Thread.Id {
    const thread_id_int = threads_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(thread_id_int);
}

pub fn newSoftInterruptHandler(
    callback: *const fn (dev: *Device) void,
    dev: *Device,
) Error!*Thread {
    const thread_id = blk: {
        const interrupts_enabled = scheduler_lock.lockInterrupt();
        defer scheduler_lock.unlockInterrupt(interrupts_enabled);
        break :blk try nextThreadIdLocked();
    };

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;

    thread.purpose = .{
        .soft_interrupt = .{
            .callback = callback,
            .dev = dev,
            .state = .unqueued,
        },
    };

    // TODO: smaller stack size or on demand by the caller
    const stack_top = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    thread.kernel_stack_top = mm.physicalToVirtual(stack_top.physical());
    thread.kernel_stack_size = std.math.shl(usize, 1, 12 + stack_size_order);
    thread.kernel_state = thread_state_cache.alloc() catch return error.out_of_memory;

    const callback_addr = @intFromPtr(callback);

    if (config.debug_scheduler) {
        std.log.debug("new soft interrupt thread(TID={}), callback: 0x{x}, kernel stack top: 0x{x}, dev: {s}", .{
            thread_id,
            callback_addr,
            stack_top.physical().int,
            dev.name,
        });
    }

    return thread;
}

/// Create a new kernel thread
pub fn newKernelThread(entry_point_fn: *const fn () void, owner_process: *Process) Error!*Thread {
    const thread_id = blk: {
        const interrupts_enabled = scheduler_lock.lockInterrupt();
        defer scheduler_lock.unlockInterrupt(interrupts_enabled);
        break :blk try nextThreadIdLocked();
    };

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;

    thread.purpose = .{
        .general = .{
            .user = null,
            .owner_process = owner_process,
            .process_list_next = null,
            .current_state = .kernelspace,
            .previous_states = .{
                .depth = 0,
                .buffer = @splat(undefined),
            },
        },
    };

    // TODO: process lock
    var next_ptr = &owner_process.associated_threads;
    while (next_ptr.*) |added_thread| {
        next_ptr = &added_thread.purpose.general.process_list_next;
    }
    next_ptr.* = thread;

    const kernel_stack_top = buddy_allocator.allocBlock(stack_size_order) catch
        return error.out_of_memory;
    thread.kernel_stack_top = mm.physicalToVirtual(kernel_stack_top.physical());
    thread.kernel_stack_size = std.math.shl(usize, 1, 12 + stack_size_order);
    thread.kernel_state = thread_state_cache.alloc() catch return error.out_of_memory;

    const entry_point: mm.VirtualAddress = .fromInt(@intFromPtr(entry_point_fn));
    arch.setupNewGeneralThread(thread, null, entry_point);
    {
        const interrupts_enabled = scheduler_lock.lockInterrupt();
        defer scheduler_lock.unlockInterrupt(interrupts_enabled);
        appendRunningThreadLocked(thread);
    }

    if (config.debug_scheduler) {
        std.log.debug("new kernel thread(TID={}), entry point: 0x{x}, kernel stack top: 0x{x}", .{
            thread_id,
            entry_point.int,
            kernel_stack_top.physical().int,
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
    const thread_id = blk: {
        const interrupts_enabled = scheduler_lock.lockInterrupt();
        defer scheduler_lock.unlockInterrupt(interrupts_enabled);
        break :blk try nextThreadIdLocked();
    };

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;

    const stack_top = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    thread.kernel_stack_top = mm.physicalToVirtual(stack_top.physical());
    thread.kernel_state = thread_state_cache.alloc() catch return error.out_of_memory;

    thread.purpose = .{
        .general = .{
            .owner_process = owner_process,
            .user = .{
                .thread_state = thread_state_cache.alloc() catch return error.out_of_memory,
            },
            .process_list_next = null,
            .current_state = .userspace,
            .previous_states = .{
                .depth = 0,
                .buffer = undefined,
            },
        },
    };

    // entering the thread for the first time
    thread.purpose.general.previous_states.push(.userspace);

    // TODO: process lock
    var next_ptr = &owner_process.associated_threads;
    while (next_ptr.*) |added_thread| {
        next_ptr = &added_thread.purpose.general.process_list_next;
    }
    next_ptr.* = thread;

    arch.setupNewGeneralThread(thread, .fromInt(user_stack_bottom_addr), .fromInt(entry_point_addr));
    {
        const interrupts_enabled = scheduler_lock.lockInterrupt();
        defer scheduler_lock.unlockInterrupt(interrupts_enabled);
        appendRunningThreadLocked(thread);
    }

    if (config.debug_scheduler) {
        std.log.debug("new user thread(TID={}), entry point: 0x{x}, kernel stack top: 0x{x}", .{
            thread_id,
            entry_point_addr,
            thread.kernel_stack_top.int,
        });
    }

    return thread;
}

/// Removes a running thread from the running queue.
/// The thread is freed thus the pointer becomes invalid.
/// The function does not schedule the new first thread.
fn removeThreadLocked(thread: *Thread) void {
    // TODO: remove from waitlist if in one
    var next_ptr = &running_threads;

    threads_available.set(@intFromEnum(thread.id));

    // TODO: maybe use a doubly linked list to avoid iterating
    while (next_ptr.*) |added_thread| : (next_ptr = &added_thread.scheduler_list_next) {
        if (added_thread != thread) continue;

        next_ptr.* = thread.scheduler_list_next;
        thread_cache.free(thread);
        return;
    }

    @panic("Trying to remove thread that is not in the running threads list");
}

pub fn dumpRunningThreads() void {
    const interrupts_enabled = scheduler_lock.lockInterrupt();
    defer scheduler_lock.unlockInterrupt(interrupts_enabled);

    std.log.debug("running threads:", .{});
    var next_ptr = &running_threads;
    while (next_ptr.*) |thread| : (next_ptr = &thread.scheduler_list_next) {
        std.log.debug("{}", .{thread.id});
    }
}

pub fn scheduleNextThread() void {
    const interrupts_enabled = scheduler_lock.lockInterrupt();
    defer scheduler_lock.unlockInterrupt(interrupts_enabled);

    const prev_thread = popCurrentThreadLocked();
    switch (prev_thread.purpose) {
        .soft_interrupt => |*soft_int| {
            if (soft_int.state == .queued) {
                appendRunningThreadLocked(prev_thread);
            } else {
                soft_int.state = .unqueued;
            }
        },
        .general => {
            appendRunningThreadLocked(prev_thread);
        },
    }
}

/// Sets
pub fn forceScheduleNextThread() void {
    // interrupts *SHOULD* already be disabled by the arch specific function that calls this
    std.log.debug("force schedule", .{});

    scheduleNextThread();
    const next_thread = getCurrentThread();

    if (next_thread.purpose == .general) {
        const general_thread = &next_thread.purpose.general;
        std.log.debug("previous states: {any}", .{
            next_thread.purpose.general.previous_states.buffer[0..next_thread.purpose.general.previous_states.depth],
        });
        general_thread.current_state = general_thread.previous_states.pop();
        std.log.debug("current state: {}", .{
            next_thread.purpose.general.current_state,
        });
    }
    arch.setTrapValues(next_thread, true);
}

pub fn destroyProcessThreads(process: *Process) void {
    const interrupts_enabled = scheduler_lock.lockInterrupt();
    defer scheduler_lock.unlockInterrupt(interrupts_enabled);

    var next_ptr = &process.associated_threads;
    while (next_ptr.*) |thread| : (next_ptr = &thread.purpose.general.process_list_next) {
        removeThreadLocked(thread);
    }
}

pub fn getCurrentThread() *Thread {
    return running_threads orelse @panic("Running threads list is empty, sentinel is not running?");
}

fn popCurrentThreadLocked() *Thread {
    const thread = running_threads orelse @panic("Running threads list is empty, sentinel is not running?");
    running_threads = thread.scheduler_list_next;
    return thread;
}

pub fn tick() void {
    scheduleNextThread();
}

/// Initialize the scheduler.
pub fn init() void {
    thread_cache = slab_allocator.createObjectCache(Thread);
    thread_state_cache = slab_allocator.createObjectCache(arch.ThreadState);
}
