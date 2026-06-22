const std = @import("std");
const arch = @import("arch/arch.zig");
const Thread = @import("Thread.zig");
const mm = @import("mem/mm.zig");
const fs = @import("fs.zig");

const Self = @This();

const max_fd = 100;

parent_id: ?Id,
id: Id,
associated_threads: std.DoublyLinkedList,
mapped_regions: std.DoublyLinkedList,
mapped_region_count: usize,
root_page_table: arch.PageTable,
mount_table: *fs.MountTable,

// TODO:
file_descriptor_table: [max_fd]?fs.OpenFile,
list_node: std.DoublyLinkedList.Node,

pub const Id = enum(u32) {
    _,
    pub const max = 4096;
};

pub const MappedRegion = struct {
    address: mm.VirtualAddress,
    size: usize,
    flags: Flags,
    next: std.DoublyLinkedList.Node,

    pub const Flags = packed struct {
        read: bool,
        write: bool,
        execute: bool,
    };
};

pub fn mapRegion(self: Self, addr: mm.VirtualAddress, size: usize, flags: MappedRegion.Flags) !void {
    // TODO: check overlap with already mapped region
    // TODO: check whether address is in userspace(< kernel higher half)

    // TODO: add regions to linked list
    try arch.mapRegion(self.root_page_table, addr, size, flags);
}
