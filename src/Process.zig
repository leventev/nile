const std = @import("std");
const arch = @import("arch/arch.zig");
const Thread = @import("Thread.zig");
const mm = @import("mem/mm.zig");
const vfs = @import("vfs.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const sync = @import("sync.zig");
const ProcessFilesystem = @import("ProcessFilesystem.zig");

const Process = @This();

const max_fd = 100;

parent: ?*Process,
id: Id,
associated_threads: ?*Thread,
mapped_regions: ?*MappedRegion,
mapped_region_count: usize,
root_page_table: arch.PageTable,
mount_table: *vfs.MountTable,

procfs: *ProcessFilesystem,

last_child_exit_code: ?isize,
last_child_exit_code_semaphore: sync.Semaphore,

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
    page_index: usize,
    page_count: usize,
    backing: ?Backing,
    flags: Flags,
    next: ?*MappedRegion,

    pub fn contains(self: MappedRegion, page_index: usize) bool {
        return page_index >= self.page_index and page_index < self.page_index + self.page_count;
    }

    pub const Backing = struct {
        source: union(enum) {
            file: struct {
                open_file: vfs.OpenFile,

                /// Offset in pages from the beginning of the file.
                page_offset: usize,
            },

            /// Will be deallocted on unmap.
            memory: [*]const u8,
        },
        /// The number of pages which the backing contains.
        page_count: usize,

        /// Offset in pages from the beginning of the mapping where the backing starts.
        page_offset: usize,
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
    page_index: usize,
    page_count: usize,
    backing: ?MappedRegion.Backing,
    flags: MappedRegion.Flags,
) MapRegionError!void {
    if (page_count == 0)
        return MapRegionError.InvalidSize;

    const hh_page_idx = arch.kernel_addresses.higher_half / arch.page_size;

    const last_page_index = page_index +% page_count - 1;
    if (page_index >= hh_page_idx or last_page_index >= hh_page_idx or last_page_index < page_index)
        return MapRegionError.InsideKernelSpace;

    var next_ptr = &self.mapped_regions;
    while (next_ptr.*) |mapped_region| : (next_ptr = &mapped_region.next) {
        const mapped_last_page_index = mapped_region.page_index + mapped_region.page_count - 1;

        const later_start = @max(page_index, mapped_region.page_index);
        const earlier_end = @min(last_page_index, mapped_last_page_index);

        if (later_start < earlier_end)
            return MapRegionError.Overlap;
    }

    const new_mapped_region = try MappedRegion.cache.alloc();
    new_mapped_region.* = .{
        .page_index = page_index,
        .page_count = page_count,
        .backing = backing,
        .flags = flags,
        .next = null,
    };
    next_ptr.* = new_mapped_region;
    self.mapped_region_count += 1;
}
