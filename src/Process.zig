const std = @import("std");
const arch = @import("arch/arch.zig");
const Thread = @import("Thread.zig");
const mm = @import("mem/mm.zig");
const vfs = @import("vfs.zig");
const slab_allocator = @import("mem/slab_allocator.zig");

const Process = @This();

const max_fd = 100;

parent_id: ?Id,
id: Id,
associated_threads: ?*Thread,
mapped_regions: ?*MappedRegion,
mapped_region_count: usize,
root_page_table: arch.PageTable,
mount_table: *vfs.MountTable,

// TODO:
file_descriptor_table: [max_fd]?struct {
    file: vfs.OpenFile,
    offset: usize,
},
next: ?*Process,

pub const Id = enum(u32) {
    _,
    pub const max = 4096;
};

pub const MappedRegion = struct {
    address: mm.UserAddress,
    size: usize,
    backing: ?Backing,
    flags: Flags,
    next: ?*MappedRegion,

    pub fn contains(self: MappedRegion, address: mm.UserAddress) bool {
        const end = self.address.add(self.size) orelse unreachable;
        return address.int >= self.address.int and address.int < end.int;
    }

    pub const Backing = struct {
        file: vfs.OpenFile,
        offset: usize,
    };

    pub const Flags = packed struct {
        read: bool,
        write: bool,
        execute: bool,
    };

    pub var cache: slab_allocator.ObjectCache(MappedRegion) = undefined;
};

pub const MapRegionError = error{
    Overlap,
    InsideKernelSpace,
    InvalidSize,
    OutOfMemory,
};

pub fn mapRegion(
    self: *Process,
    address: mm.UserAddress,
    size: usize,
    backing: ?MappedRegion.Backing,
    flags: MappedRegion.Flags,
) !void {
    if (size == 0)
        return MapRegionError.InvalidSize;

    var next_ptr = &self.mapped_regions;
    while (next_ptr.*) |mapped_region| : (next_ptr = &mapped_region.next) {
        const new_end = address.add(size) orelse return MapRegionError.InsideKernelSpace;
        const mapped_end = mapped_region.address.add(mapped_region.size) orelse unreachable;

        const later_start = @max(address.int, mapped_region.address.int);
        const earlier_end = @min(new_end.int, mapped_end.int);

        if (later_start < earlier_end)
            return MapRegionError.Overlap;
    }

    const new_mapped_region = try MappedRegion.cache.alloc();
    new_mapped_region.* = .{
        .address = address,
        .size = size,
        .backing = backing,
        .flags = flags,
        .next = null,
    };
    next_ptr.* = new_mapped_region;
    self.mapped_region_count += 1;
}
