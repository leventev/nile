const std = @import("std");
const config = @import("config.zig");
const Thread = @import("Thread.zig");
const slab_allocator = @import("mem/slab_allocator.zig");

const log = std.log.scoped(.scheduler);

pub var running_threads: std.SinglyLinkedList = .{};
pub var threads_available = std.bit_set.ArrayBitSet(usize, Thread.Id.max).initFull();

var thread_cache: slab_allocator.ObjectCache(Thread) = .{};

pub const Error = error{
    no_available_threads,
    out_of_memory,
};

/// Append a thread at the end of the running threads linked list.
fn appendRunningThread(thread: *Thread) void {
    var node: *?*std.SinglyLinkedList.Node = &running_threads.first;
    while (node.*) |next_ptr| : (node = &next_ptr.next) {
        // check whether a thread is already added

        if (config.debug_scheduler) {
            if (@intFromPtr(next_ptr) == @intFromPtr(&thread.list_node)) {
                std.debug.panicExtra(
                    null,
                    "trying to append an already queued thread to running threads list, TID: {}",
                    .{@intFromEnum(thread.id)},
                );
            }
        }
    }

    node.* = &thread.list_node;
    thread.list_node.next = null;
}

/// Get the lowest available thread ID
fn nextThreadId() Error!Thread.Id {
    const thread_id_int = threads_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(thread_id_int);
}

/// Create a new kernel thread
fn newKernelThread() Error!Thread.Id {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;
    thread.level = .kernel;

    appendRunningThread(thread);

    return thread_id;
}

/// Initialize the scheduler.
/// A sentinel kernel thread is create with TID 0 and always runs.
pub fn init() void {
    thread_cache = slab_allocator.createObjectCache(Thread);

    const id = newKernelThread() catch unreachable;
    log.info("sentinel thread id: {}", .{@intFromEnum(id)});
    if (config.debug_scheduler)
        std.debug.assert(@intFromEnum(id) == 0);
    const id2 = newKernelThread() catch unreachable;
    log.info("thread id: {}", .{@intFromEnum(id2)});
}
