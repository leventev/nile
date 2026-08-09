const std = @import("std");
const arch = @import("../arch/arch.zig");
const mm = @import("mm.zig");
const buddy_allocator = @import("buddy_allocator.zig");
const sync = @import("../sync.zig");

pub const PageDescriptor = struct {
    reference_count: std.atomic.Value(usize),
};

pub const Region = struct {
    frame_number: usize,
    frame_count: usize,
    descriptors: []PageDescriptor,
};

pub const max_region_count = 32;
pub var page_descriptors = struct {
    spinlock: sync.Spinlock = .unlocked,
    regions: [max_region_count]Region = undefined,
    region_count: usize = 0,
    initialized: bool = false,
}{};

var page_descriptor_stub: PageDescriptor = .{
    .reference_count = .init(0),
};

pub fn getDescriptor(address: mm.PhysicalAddress) *PageDescriptor {
    std.debug.assert(address.int % arch.page_size == 0);
    const pfn = address.int / arch.page_size;

    // TODO: lock interrupt?
    page_descriptors.spinlock.lock();
    defer page_descriptors.spinlock.unlock();

    if (!page_descriptors.initialized)
        return &page_descriptor_stub;

    for (0..page_descriptors.region_count) |i| {
        const region = &page_descriptors.regions[i];
        // std.log.debug("{}: start: {} end: {} pfn: {}", .{
        //     i,
        //     region.frame_number,
        //     region.frame_number + region.frame_count,
        //     pfn,
        // });
        if (pfn < region.frame_number and pfn >= region.frame_count + region.frame_count)
            continue;

        const relative_pfn = pfn - region.frame_number;
        return &region.descriptors[relative_pfn];
    }

    unreachable;
}

pub fn init(root_page_table: mm.PageTable, free_regions: []const mm.MemoryRegion) !void {
    try arch.setupPageDescriptors(root_page_table, free_regions);
}
