const Thread = @import("Thread.zig");

parent_id: ?Id,
id: Id,
user_thread: Thread,

pub const Id = enum(u32) {
    _,
    pub const max = 4096;
};
