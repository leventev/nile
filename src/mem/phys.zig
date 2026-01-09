const mm = @import("mm.zig");
const std = @import("std");
const kio = @import("../kio.zig");

const LineType = u64;
const frames_per_line = @bitSizeOf(LineType);
const bitmap_line_full = std.math.maxInt(LineType);

const PageFrameRegion = struct {
    address: mm.PhysicalAddress,
    bitmap: std.bit_set.DynamicBitSetUnmanaged,

    fn full(self: PageFrameRegion) bool {
        return self.bitmap.count() == 0;
    }

    fn alloc(self: *PageFrameRegion) mm.PhysicalAddress {
        if (self.full())
            @panic("Trying to allocate from frame region with no free frames available");

        const frame_idx = self.bitmap.findFirstSet() orelse
            @panic("Unable to find available page despite not being full");

        return .make(self.address.asInt() + @as(u64, @intCast(frame_idx)) * mm.page_size);
    }

    fn free(self: *PageFrameRegion, addr: mm.PhysicalAddress) void {
        const address = addr.asInt() - self.address.asInt();
        const frame_idx = address / mm.frame_size;
        self.bitmap.unset(frame_idx);
    }

    fn contains(self: PageFrameRegion, addr: mm.PhysicalAddress) bool {
        const address = addr.asInt();
        const this_address = self.address.asInt();

        if (address < this_address) return false;
        const relative_addr = address - this_address;
        const frame_index = relative_addr / mm.frame_size;

        return frame_index < self.total_frame_count;
    }
};

// TODO: thread safety
const PhysicalFrameAllocator = struct {
    regions: []PageFrameRegion,
    total_frame_count: usize,
    free_frame_count: usize,

    fn alloc(self: *PhysicalFrameAllocator) !mm.PhysicalAddress {
        if (self.full())
            return error.OutOfMemory;

        for (self.regions) |*region| {
            if (region.full())
                continue;

            const addr = region.alloc();
            self.free_frame_count -= 1;
            return addr;
        }

        @panic("Can not find a free frame but freeFrameCount != 0");
    }

    fn free(self: *PhysicalFrameAllocator, addr: mm.PhysicalAddress) void {
        if (!addr.isPageAligned())
            @panic("Address is not page aligned");

        for (self.regions) |*region| {
            if (!region.contains(addr))
                continue;

            region.free(addr);
            self.free_frame_count += 1;
            return;
        }

        @panic("Invalid address");
    }

    fn full(self: PhysicalFrameAllocator) bool {
        return self.free_frame_count == 0;
    }
};

var frame_allocator: PhysicalFrameAllocator = undefined;

pub fn init(gpa: std.mem.Allocator, regions: []const mm.MemoryRegion) !void {
    var regs = try gpa.alloc(PageFrameRegion, regions.len);

    var total_frames: usize = 0;
    var total_lines: usize = 0;

    for (regions, 0..) |physReg, i| {
        const address = mm.PhysicalAddress.make(physReg.start);
        const frame_count: usize = physReg.size / mm.frame_size;
        const lines_required = std.math.divCeil(usize, frame_count, frames_per_line) catch unreachable;

        const bitmap = try gpa.alloc(LineType, lines_required);
        @memset(bitmap, 0);

        total_frames += frame_count;
        total_lines += lines_required;

        regs[i] = PageFrameRegion{
            .address = address,
            .bitmap = try .initFull(gpa, frame_count),
        };
    }

    frame_allocator = PhysicalFrameAllocator{
        .regions = regs,
        .total_frame_count = total_frames,
        .free_frame_count = total_frames,
    };

    std.log.info("Physical frame allocator initialized with {} frames ({} KiB) available", .{
        total_frames,
        total_frames * 4,
    });
    std.log.info("{} bytes allocated for bitmaps", .{@sizeOf(LineType) * total_lines});
}

pub fn alloc() !mm.PhysicalAddress {
    return frame_allocator.alloc();
}

pub fn free(addr: mm.PhysicalAddress) void {
    frame_allocator.free(addr);
}
