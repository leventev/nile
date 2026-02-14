const std = @import("std");
const config = @import("config.zig");
const Thread = @import("Thread.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const buddy_allocator = @import("mem/buddy_allocator.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");

const log = std.log.scoped(.scheduler);

const stack_size_order = 4;
const stack_size = @shlExact(1, stack_size_order) * 4096;

pub var running_threads: std.SinglyLinkedList = .{
    .first = &sentinel_thread.list_node,
};
pub var threads_available = std.bit_set.ArrayBitSet(usize, Thread.Id.max).initFull();

var thread_cache: slab_allocator.ObjectCache(Thread) = .{};

extern const __stack_top: void;

var sentinel_thread: Thread = .{
    .id = @enumFromInt(0),
    .level = .kernel,
    .registers = undefined,
    .stack_top = undefined,
    .list_node = .{ .next = null },
};

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
pub fn newKernelThread(entry_point: *const fn () void) Error!Thread.Id {
    const thread_id = try nextThreadId();

    var thread: *Thread = thread_cache.alloc() catch return error.out_of_memory;
    thread.id = thread_id;
    thread.level = .kernel;

    const stack_bottom = buddy_allocator.allocBlock(stack_size_order) catch return error.out_of_memory;
    const stack_top = mm.PhysicalAddress.make(stack_bottom.asInt() + stack_size);
    thread.stack_top = mm.physicalToHHDMAddress(stack_top);

    const entry_point_addr = @intFromPtr(entry_point);
    arch.setupNewThread(thread, entry_point_addr, thread.stack_top.asInt());
    appendRunningThread(thread);

    if (config.debug_scheduler) {
        std.log.debug("new thread(TID={}) with entry point: 0x{x}", .{ thread_id, entry_point_addr });
    }

    return thread_id;
}

fn scheduleNextThread() void {
    const prev_thread_node = running_threads.popFirst() orelse @panic("No running threads?");
    const prev_thread: *Thread = @fieldParentPtr("list_node", prev_thread_node);
    appendRunningThread(prev_thread);

    const next_thread_node = running_threads.first orelse unreachable;
    const next_thread: *Thread = @fieldParentPtr("list_node", next_thread_node);
    arch.scheduleNextThread(next_thread);
}

pub fn tick() void {
    scheduleNextThread();
}

/// Initialize the scheduler.
/// A statically allocated sentinel kernel thread always runs with TID 0.
pub fn init() void {
    thread_cache = slab_allocator.createObjectCache(Thread);
    threads_available.unset(@intFromEnum(sentinel_thread.id));
    sentinel_thread.stack_top = .make(@intFromPtr(&__stack_top));

    arch.scheduleNextThread(&sentinel_thread);
}
