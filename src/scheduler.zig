const std = @import("std");
const Thread = @import("Thread.zig");

// TODO: consider making 'threads' static, since reallocations
// can invalidate pointers leading to invalid pointers
// but since thread handling functions are only supposed to be in
// scheduler.zig and other systems refer to threads with their IDs
// this might not actually be a problem
pub var threads = std.ArrayList(Thread){};
pub var threads_available = std.bit_set.ArrayBitSet(usize, Thread.Id.max).initEmpty();

pub fn init(gpa: std.mem.Allocator) void {
    std.debug.assert(threads_available.count() == Thread.Id.max);

    threads = .initCapacity(gpa, 64);

    // create sentinel thread
    threads_available.unset(0);
    threads.append(gpa, .{
        .id = 0,
        .level = .kernel,
    });
}
