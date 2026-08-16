const std = @import("std");
const builtin = @import("builtin");

const arch = @import("../arch/arch.zig");
const mm = @import("mm.zig");

const log = std.log.scoped(.buddy_allocator);

const PhysicalAddress = mm.PhysicalAddress;

pub const order_count = 12;
pub const max_order = order_count - 1;

/// Allocates contiguous physical blocks with 2^n frames, where n is called the order.
/// The minimum order is 0 and the maximum is max_order.
pub const BuddyAllocator = struct {
    /// The list of all orders.
    orders: [order_count]Order = [_]Order{Order{
        .free_block_count = 0,
        .first = null,
    }} ** order_count,

    /// Keeps track of the free blocks in a given order.
    pub const Order = struct {
        /// List of all free blocks in the order.
        first: ?*Node,

        /// The number of free blocks in the order.
        free_block_count: usize,

        const Node = struct { next: ?*Node };

        /// Add a block to the free list. The list of block addresses is always ordered
        /// in ascending order.
        pub fn orderedAdd(self: *Order, block_addr: PhysicalAddress) void {
            const virt_addr = mm.physicalToVirtual(block_addr);
            const new_node = virt_addr.asPtr(*Node);

            self.free_block_count += 1;

            var next_ptr = &self.first;
            while (next_ptr.*) |existing_node| : (next_ptr = &existing_node.next) {
                if (@intFromPtr(new_node) < @intFromPtr(existing_node)) {
                    next_ptr.* = new_node;
                    new_node.next = existing_node;
                    return;
                }
            }

            // last element
            next_ptr.* = new_node;
            new_node.next = null;
        }
    };

    /// Used for initializing the buddy allocator from the physical memory regions
    /// provided by the device tree.
    pub fn addBlocksFromRegion(self: *BuddyAllocator, start_page_idx: usize, page_count: usize) void {
        const end_page_idx = start_page_idx + page_count;

        var order: usize = max_order;
        while (order >= 1) : (order -= 1) {
            // 1. find the largest order that can fit inside the region
            const block_size_in_pages = std.math.shl(usize, 1, order);
            if (block_size_in_pages > page_count) continue;

            // 2. check whether a block of this order would actually fit inside this region
            // for example a region from 8-78 could theoretically fit a 6th order(2^6 = 64 page) block
            // but because a 6th order block can only start from page index 0, 64, 128, ...
            // we have to use lower order pages

            const next_aligned_page_idx =
                if (start_page_idx % block_size_in_pages == 0)
                    start_page_idx
                else
                    start_page_idx + (block_size_in_pages - start_page_idx % block_size_in_pages);

            const remaining_page_count = end_page_idx - next_aligned_page_idx;
            const block_count = remaining_page_count / block_size_in_pages;
            if (block_count < 1) continue;

            // 3. add blocks to the free list
            // block_count should only exceed one if order == max_order
            // since otherwise the contiguous blocks would form a higher order block

            for (0..block_count) |i| {
                const block_page_idx = next_aligned_page_idx + i * block_size_in_pages;
                const block_addr = PhysicalAddress.fromInt(block_page_idx * arch.page_size);

                self.orders[order].orderedAdd(block_addr);
            }

            const last_block_end_page_idx = next_aligned_page_idx + block_count * block_size_in_pages;

            // 4. add remaining leading and trailing regions as well
            // the maximum depth of recursion is less than order_count

            if (next_aligned_page_idx != start_page_idx) {
                const leading_region_page_idx = start_page_idx;
                const leading_region_page_count = next_aligned_page_idx - start_page_idx;
                self.addBlocksFromRegion(leading_region_page_idx, leading_region_page_count);
            }

            if (last_block_end_page_idx != end_page_idx) {
                const trailing_region_page_idx = last_block_end_page_idx;
                const trailing_region_page_count = end_page_idx - last_block_end_page_idx;
                self.addBlocksFromRegion(trailing_region_page_idx, trailing_region_page_count);
            }

            return;
        }

        // if the smallest possible order is 0th then we just add all pages to the free list

        for (0..page_count) |i| {
            const block_page_idx = start_page_idx + i;
            const block_addr = PhysicalAddress.fromInt(block_page_idx * arch.page_size);
            self.orders[0].orderedAdd(block_addr);
        }
    }

    pub const Error = error{
        InvalidOrder,
        OutOfMemory,
    };

    /// Tries to remove a free block from a certain order.
    /// Returns whether the block was in the free list of the specified order.
    pub fn removeBlock(self: *BuddyAllocator, order: usize, block_address: PhysicalAddress) bool {
        const virt_addr = mm.physicalToVirtual(block_address);
        const removed_node = virt_addr.asPtr(*Order.Node);

        var next_ptr = &self.orders[order].first;
        while (next_ptr.*) |node| : (next_ptr = &node.next) {
            if (@intFromPtr(node) == @intFromPtr(removed_node)) {
                next_ptr.* = removed_node.next;
                self.orders[order].free_block_count -= 1;
                return true;
            }
        }

        return false;
    }

    /// Allocates a block of a given order.
    pub fn allocBlock(
        self: *BuddyAllocator,
        desired_order: usize,
    ) Error!*mm.FrameDescriptor {
        if (desired_order > max_order) return error.InvalidOrder;

        // find the lowest order that has a free block
        var order = desired_order;
        while (order <= max_order and self.orders[order].free_block_count == 0) : (order += 1) {}

        if (order > max_order) return error.OutOfMemory;

        // for simplicity's sake we always try to select the leftmost block
        const first_block =
            if (self.orders[order].first) |first_block| blk: {
                self.orders[order].first = first_block.next;
                break :blk first_block;
            } else null;

        if (first_block) |block| {
            // when we split an N order block into two N-1 order blocks we always select the
            // left N-1 block so the address always stays the same
            const virt_addr: mm.VirtualAddress = .fromInt(@intFromPtr(block));
            const phys_addr = mm.virtualToPhysical(virt_addr);
            self.orders[order].free_block_count -= 1;

            // keep splitting the blocks until we reach the desired order
            while (order > desired_order) {
                order -= 1;
                const block_size_in_pages = std.math.shl(usize, 1, order);
                const offset = block_size_in_pages * arch.page_size;
                const right_block_addr = phys_addr.add(offset);
                self.orders[order].orderedAdd(right_block_addr);
            }

            const frame_descriptor = mm.getFrameDescriptor(phys_addr);
            frame_descriptor.block_order = desired_order;
            // only increase the first page's refcount in the block
            _ = frame_descriptor.reference_count.fetchAdd(1, .monotonic);

            return frame_descriptor;
        } else return error.OutOfMemory;
    }

    /// Deallocates a block of a given order.
    pub fn deallocBlock(
        self: *BuddyAllocator,
        frame_descriptor: *mm.FrameDescriptor,
    ) void {
        std.debug.assert(frame_descriptor.block_order <= max_order);
        var order = frame_descriptor.block_order;
        var address = frame_descriptor.physical();

        // we try to coalesce the specified block and its buddy
        while (order <= max_order) : (order += 1) {
            // buddy's address can be calculated by XOR-ing with the size
            const block_size = std.math.shl(usize, 1, order) * arch.page_size;
            const buddy_address = PhysicalAddress.fromInt(address.int ^ block_size);

            // if the buddy is free then we remove it and move on to the next order
            const buddy_is_free = self.removeBlock(order, buddy_address);
            if (!buddy_is_free) {
                break;
            }

            address = .fromInt(@min(address.int, buddy_address.int));
        }

        self.orders[order].orderedAdd(address);
    }
};

var global_buddy_allocator: BuddyAllocator = .{};

/// Initializes the buddy allocator from the list of physical memory regions provided by
/// the device tree.
pub fn init(regions: []const mm.UsableMemoryRegion) void {
    var total_frames: usize = 0;

    for (regions) |region| {
        const usable_frame_count = region.range.frame_count - region.reserved_frame_count;
        if (usable_frame_count == 0) continue;

        total_frames += usable_frame_count;

        const first_frame = region.range.frame_number + region.reserved_frame_count;

        global_buddy_allocator.addBlocksFromRegion(first_frame, usable_frame_count);
    }

    // for (0.., global_buddy_allocator.orders) |i, order| {
    //     std.log.info("Order #{}: {} free blocks", .{ i, order.free_block_count });
    //     var block_list_node = order.list.first;
    //     while (block_list_node) |list_node| : (block_list_node = list_node.next) {
    //         std.log.info("addr: {x}", .{@intFromPtr(list_node)});
    //     }
    // }

    log.info("Buddy allocator allocator initialized with {} frames ({} KiB) available", .{
        total_frames,
        total_frames * 4,
    });
}

pub var testing_buddy_allocator: ?*BuddyAllocator = null;

const global_not_allowed =
    \\ Global buddy allocator is not allowed in tests since Zig tests are ran in an unknown order
    \\ and global variables persist between tests. To use a buddy allocator in tests outside
    \\ buddy_allocator.zig set testing_buddy_allocator to a local BuddyAllocator{}.
    \\ With a GPA allocate a buffer(s) with (1 << order) * page_size size and alignment, then
    \\ add to the respective order with BuddyAllocator.orders[order].orderedAdd().
;

/// Allocates a block of a given order.
pub fn allocBlock(desired_order: usize) BuddyAllocator.Error!*mm.FrameDescriptor {
    return global_buddy_allocator.allocBlock(desired_order);
}

/// Deallocates a block of a given order.
pub fn deallocBlock(frame_descriptor: *mm.FrameDescriptor) void {
    global_buddy_allocator.deallocBlock(frame_descriptor);
}

// TODO: maybe make it comptime T?
pub fn blockOrderFromSize(size: u64) usize {
    var order: usize = 0;
    var s = size;
    while (s > 4096) {
        order += 1;
        s = std.math.shr(u64, s, 1);
    }

    return order;
}

test "alloc basic" {
    const gpa = std.testing.allocator;
    const alloced_size = comptime std.math.shl(usize, 1, max_order) * mm.page_size;
    const mem = try gpa.allocWithOptions(
        u8,
        alloced_size,
        std.mem.Alignment.fromByteUnits(alloced_size),
        null,
    );
    defer gpa.free(mem);

    var buddy_allocator = BuddyAllocator{};
    const base_address = PhysicalAddress.make(@intFromPtr(mem.ptr));
    buddy_allocator.orders[max_order].orderedAdd(base_address);

    // they should be equal because of the lower address bias of the allocator
    const one_page_addr = try buddy_allocator.allocBlock(0);
    try std.testing.expectEqual(base_address, one_page_addr);
    const one_page_addr_2 = try buddy_allocator.allocBlock(0);
    try std.testing.expectEqual(
        PhysicalAddress.make(base_address.int + mm.page_size),
        one_page_addr_2,
    );

    try std.testing.expectEqual(0, buddy_allocator.orders[10].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[9].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[8].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[7].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[6].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[5].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[4].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[3].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[2].free_block_count);
    try std.testing.expectEqual(1, buddy_allocator.orders[1].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[0].free_block_count);
    try std.testing.expectEqual(base_address.int, one_page_addr.int);

    buddy_allocator.deallocBlock(one_page_addr, 0);
    buddy_allocator.deallocBlock(one_page_addr_2, 0);
    try std.testing.expectEqual(1, buddy_allocator.orders[10].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[9].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[8].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[7].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[6].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[5].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[4].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[3].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[2].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[1].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[0].free_block_count);
}

test "alloc complex" {
    const gpa = std.testing.allocator;
    const alloced_size = comptime std.math.shl(usize, 1, max_order) * mm.page_size;
    const mem = try gpa.allocWithOptions(
        u8,
        alloced_size,
        std.mem.Alignment.fromByteUnits(alloced_size),
        null,
    );
    defer gpa.free(mem);

    var buddy_allocator = BuddyAllocator{};
    const base_address = PhysicalAddress.make(@intFromPtr(mem.ptr));
    buddy_allocator.orders[max_order].orderedAdd(base_address);

    var blocks = std.ArrayList(PhysicalAddress){};
    defer blocks.deinit(gpa);

    // allocate one of each except max_order
    for (0..order_count - 1) |i| {
        try blocks.append(gpa, try buddy_allocator.allocBlock(i));
    }

    // there should be only one remaining
    const last = try buddy_allocator.allocBlock(0);

    for (0..order_count) |i| {
        try std.testing.expectEqual(0, buddy_allocator.orders[i].free_block_count);
    }

    for (0..order_count - 1) |i| {
        buddy_allocator.deallocBlock(blocks.items[i], i);
    }

    buddy_allocator.deallocBlock(last, 0);

    try std.testing.expectEqual(1, buddy_allocator.orders[10].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[9].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[8].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[7].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[6].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[5].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[4].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[3].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[2].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[1].free_block_count);
    try std.testing.expectEqual(0, buddy_allocator.orders[0].free_block_count);
}

// TODO: test to check whether orderedAdd actually orders them
