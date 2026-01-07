const mm = @import("mm.zig");
const std = @import("std");
const kio = @import("../kio.zig");

const LineType = u64;
const frames_per_line = @bitSizeOf(LineType);
const bitmap_line_full = std.math.maxInt(LineType);

const PageFrameRegion = struct {
    address: mm.PhysicalAddress,
    total_frame_count: usize,
    free_frame_count: usize,
    bitmap: []LineType,
    first_free_line_idx: usize,

    const Self = @This();

    fn full(self: Self) bool {
        return self.free_frame_count == 0;
    }

    fn alloc(self: *Self) mm.PhysicalAddress {
        if (self.full())
            @panic("Trying to allocate from frame region with no free frames available");

        // NOTE: we could store the frame index instead of just the bitmap index
        // but that would introduce an extra if statement and i believe it's prettier this way :)
        for (self.first_free_line_idx..self.bitmap.len) |lineIdx| {
            const line = self.bitmap[lineIdx];
            if (line == bitmap_line_full)
                continue;

            for (0..frames_per_line) |bitIdx| {
                const bit: LineType = std.math.shl(LineType, 1, bitIdx);
                const allocated = line & bit > 0;
                if (allocated)
                    continue;

                self.first_free_line_idx = lineIdx;
                self.bitmap[lineIdx] |= bit;
                self.free_frame_count -= 1;

                const address = self.address.asInt() + (lineIdx * frames_per_line + bitIdx) * mm.frame_size;
                return mm.PhysicalAddress.make(address);
            }
        }

        @panic("Can not find a free frame but freeFrameCount != 0");
    }

    fn free(self: *Self, addr: mm.PhysicalAddress) void {
        const address = addr.asInt() - self.address.asInt();
        const line_idx = address / frames_per_line;
        const bit_idx = address % frames_per_line;

        const bit = std.math.shl(LineType, 1, bit_idx);

        self.bitmap[line_idx] &= ~bit;
        self.free_frame_count += 1;
    }

    fn contains(self: Self, addr: mm.PhysicalAddress) bool {
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

    const Self = @This();

    fn alloc(self: *Self) !mm.PhysicalAddress {
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

    fn free(self: *Self, addr: mm.PhysicalAddress) void {
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

    fn full(self: Self) bool {
        return self.free_frame_count == 0;
    }
};

var frame_allocator: PhysicalFrameAllocator = undefined;

pub fn init(allocator: std.mem.Allocator, regions: []const mm.MemoryRegion) !void {
    // TODO: do some kind of magic so we don't depend on the temporary allocator

    var regs = try allocator.alloc(PageFrameRegion, regions.len);

    var total_frames: usize = 0;
    var total_lines: usize = 0;

    for (regions, 0..) |physReg, i| {
        const address = mm.PhysicalAddress.make(physReg.start);
        const frame_count: usize = physReg.size / mm.frame_size;
        const lines_required = std.math.divCeil(usize, frame_count, frames_per_line) catch unreachable;

        const bitmap = try allocator.alloc(LineType, lines_required);
        @memset(bitmap, 0);

        total_frames += frame_count;
        total_lines += lines_required;

        regs[i] = PageFrameRegion{
            .address = address,
            .total_frame_count = frame_count,
            .free_frame_count = frame_count,
            .bitmap = bitmap,
            .first_free_line_idx = 0,
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
