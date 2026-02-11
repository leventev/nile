const std = @import("std");

id: Id,
level: Level,
list_node: std.SinglyLinkedList.Node,

pub const Id = enum(usize) {
    _,
    pub const max = 8192;
};

pub const Level = enum {
    kernel,
    user,
};
