const std = @import("std");
const config = @import("config.zig");
const Thread = @import("Thread.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const buddy_allocator = @import("mem/buddy_allocator.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");

const log = std.log.scoped(.scheduler);

const stack_size_order = 4;
const stack_size = @shlExact(1, stack_size_order) * 4096;

pub var running_threads: std.DoublyLinkedList = .{};
pub var threads_available = std.bit_set.ArrayBitSet(usize, Thread.Id.max).initFull();

var thread_cache: slab_allocator.ObjectCache(Thread) = .{};

pub const Error = error{
    no_available_threads,
    out_of_memory,
};

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

/// Create a new kernel thread
pub fn newKernelThread(entry_point: *const fn () void, owner_process: *Process) Error!*Thread {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;
    thread.owner_process = owner_process;
    thread.level = .kernel;
    thread.process_list_node = .{};

    owner_process.associated_threads.append(&thread.process_list_node);

    const stack_bottom = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    const stack_top = stack_bottom.add(stack_size);
    thread.stack_top = mm.physicalToVirtualAddress(stack_top);

    const stack_top_addr = thread.stack_top.asInt();

    const entry_point_addr = @intFromPtr(entry_point);
    arch.setupNewThread(thread, entry_point_addr, stack_top_addr, false);
    appendRunningThread(thread);

    if (config.debug_scheduler) {
        std.log.debug("new kernel thread(TID={}), entry point: 0x{x}, stack top: 0x{x}", .{
            thread_id,
            entry_point_addr,
            stack_top_addr,
        });
    }

    return thread;
}

/// Create a new user thread
pub fn newUserThread(
    entry_point_addr: usize,
    stack_top_addr: usize,
    owner_process: *Process,
) Error!*Thread {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;
    thread.owner_process = owner_process;
    thread.level = .user;
    thread.process_list_node = .{};

    owner_process.associated_threads.append(&thread.process_list_node);

    arch.setupNewThread(thread, entry_point_addr, stack_top_addr, true);
    appendRunningThread(thread);

    if (config.debug_scheduler) {
        std.log.debug("new user thread(TID={}), entry point: 0x{x}, stack top: 0x{x}", .{
            thread_id,
            entry_point_addr,
            stack_top_addr,
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

fn dumpRunningThreads() void {
    // TODO: locking here too

    std.log.debug("running threads:", .{});
    var node = running_threads.first;
    while (node) |node_ptr| : (node = node_ptr.next) {
        const thread: *Thread = @fieldParentPtr("scheduler_list_node", node_ptr);
        std.log.debug("{}", .{thread.id});
    }
}

fn scheduleNextThread() void {
    const prev_thread = popCurrentThread();
    appendRunningThread(prev_thread);

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
