const std = @import("std");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");

id: Id,
level: Level,
list_node: std.SinglyLinkedList.Node,
registers: arch.Registers,
stack_top: mm.VirtualAddress,

pub const Id = enum(usize) {
    _,
    pub const max = 8192;
};

pub const Level = enum {
    kernel,
    user,
};
