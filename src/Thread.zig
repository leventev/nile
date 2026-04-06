const std = @import("std");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");

id: Id,
owner_process: *Process,
level: Level,
scheduler_list_node: std.DoublyLinkedList.Node,
process_list_node: std.DoublyLinkedList.Node,
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
