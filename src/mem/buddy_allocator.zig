const std = @import("std");
const builtin = @import("builtin");

const arch = @import("../arch/arch.zig");
const mm = @import("mm.zig");

const PhysicalAddress = arch.PhysicalAddress;

const order_count = 11;
const max_order = order_count - 1;

pub const BuddyAllocator = struct {
    orders: [order_count]Order = [_]Order{Order{ .free_block_count = 0, .list = .{} }} ** order_count,

    pub const Order = struct {
        list: std.DoublyLinkedList,
        free_block_count: usize,

        pub fn orderedAdd(self: *Order, block_addr: PhysicalAddress) void {
            const virt_addr = mm.physicalToHHDMAddress(block_addr);
            const node_ptr: *std.DoublyLinkedList.Node = @ptrFromInt(virt_addr.asInt());

            // TODO: possibly clean this up and get rid of the special cases
            const first_node = self.list.first;
            if (first_node) |first| {
                if (@intFromPtr(node_ptr) < @intFromPtr(first)) {
                    self.list.prepend(node_ptr);
                } else {
                    var list_node = first_node;
                    while (list_node) |node| {
                        const next_list_node = node.next;
                        if (next_list_node) |next_node| {
                            if (@intFromPtr(node_ptr) < @intFromPtr(next_node)) {
                                self.list.insertAfter(node, node_ptr);
                                break;
                            }
                        } else {
                            self.list.insertAfter(node, node_ptr);
                        }

                        list_node = next_list_node;
                    }
                }
            } else {
                self.list.prepend(node_ptr);
            }

            self.free_block_count += 1;
        }
    };

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
                const block_addr = PhysicalAddress.make(block_page_idx * mm.page_size);

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
            const block_addr = arch.PhysicalAddress.make(block_page_idx * mm.page_size);
            self.orders[0].orderedAdd(block_addr);
        }
    }

    pub const Error = error{
        InvalidOrder,
        OutOfMemory,
    };

    /// Returns whether the specified block was in the list
    pub fn removeBlock(self: *BuddyAllocator, order: usize, block_address: PhysicalAddress) bool {
        var list_node = self.orders[order].list.first;
        const virt_addr = mm.physicalToHHDMAddress(block_address);
        const node_ptr: *std.DoublyLinkedList.Node = @ptrFromInt(virt_addr.asInt());

        while (list_node) |node| : (list_node = node.next) {
            if (node == node_ptr) {
                self.orders[order].list.remove(node_ptr);
                self.orders[order].free_block_count -= 1;
                return true;
            }
        }

        return false;
    }

    pub fn allocBlock(
        self: *BuddyAllocator,
        desired_order: usize,
    ) Error!PhysicalAddress {
        if (desired_order > max_order) return error.InvalidOrder;

        // find the lowest order that has a free block
        var order = desired_order;
        while (order <= max_order and self.orders[order].free_block_count == 0) : (order += 1) {}

        if (order > max_order) return error.OutOfMemory;

        // for simplicity's sake we always try to select the leftmost block
        // to bias lower addresses hence popFirst() instead pop()
        if (self.orders[order].list.popFirst()) |list_node| {
            const virt_addr: mm.VirtualAddress = .make(@intFromPtr(list_node));
            const phys_addr = mm.virtualToPhysicalAddress(virt_addr);
            // when we split an N order block into two N-1 order blocks we always select the
            // left N-1 block so the address always stays the same
            self.orders[order].free_block_count -= 1;

            // keep splitting the blocks until we reach the desired order
            while (order > desired_order) {
                order -= 1;
                const block_size_in_pages = std.math.shl(usize, 1, order);
                const offset = block_size_in_pages * mm.page_size;
                const right_block_addr = PhysicalAddress.make(phys_addr.asInt() + offset);
                self.orders[order].orderedAdd(right_block_addr);
            }

            return phys_addr;
        } else return error.OutOfMemory;
    }

    pub fn deallocBlock(
        self: *BuddyAllocator,
        block_address: PhysicalAddress,
        block_order: usize,
    ) void {
        std.debug.assert(block_order <= max_order);
        var order = block_order;
        var address = block_address;

        // we try to coalesce the specified block and its buddy
        while (order <= max_order) : (order += 1) {
            // buddy's address can be calculated by XOR-ing with the size
            const block_size = std.math.shl(usize, 1, order) * mm.page_size;
            const buddy_address = PhysicalAddress.make(address.asInt() ^ block_size);

            // if the buddy is free then we remove it and move on to the next order
            const buddy_is_free = self.removeBlock(order, buddy_address);
            if (!buddy_is_free) {
                break;
            }

            address = .make(@min(address.asInt(), buddy_address.asInt()));
        }

        self.orders[order].orderedAdd(address);
    }
};

var global_buddy_allocator: BuddyAllocator = .{};

pub fn init(regions: []const mm.MemoryRegion) void {
    var total_frames: usize = 0;

    for (regions) |region| {
        const frame_count: usize = region.size / mm.frame_size;
        total_frames += frame_count;

        // TODO: convert the fields of mm.MemoryRegion to be page indices instead of absolute addresses
        const start_page_index: usize = region.start / mm.page_size;
        const page_count: usize = region.size / mm.page_size;
        global_buddy_allocator.addBlocksFromRegion(start_page_index, page_count);
    }

    for (0.., global_buddy_allocator.orders) |i, order| {
        std.log.info("Order #{}: {} free blocks", .{ i, order.free_block_count });
        var block_list_node = order.list.first;
        while (block_list_node) |list_node| : (block_list_node = list_node.next) {
            std.log.info("addr: {x}", .{@intFromPtr(list_node)});
        }
    }

    std.log.info("Buddy allocator allocator initialized with {} frames ({} KiB) available", .{
        total_frames,
        total_frames * 4,
    });
}

const global_not_allowed =
    \\ Global buddy allocator is not allowed in tests.
    \\ To use a buddy allocator in tests create one with BuddyAllocator{}, with the testing
    \\ allocator allocate a buffer(s) with (1 << order) * page_size alignment, then
    \\ add to the respective order with BuddyAllocator.orders[order].orderedAdd().
;

pub fn allocBlock(
    desired_order: usize,
) BuddyAllocator.Error!PhysicalAddress {
    if (builtin.is_test)
        @compileError(global_not_allowed);

    return global_buddy_allocator.allocBlock(desired_order);
}

pub fn deallocBlock(
    block_address: PhysicalAddress,
    block_order: usize,
) void {
    if (builtin.is_test)
        @compileError(global_not_allowed);

    global_buddy_allocator.deallocBlock(block_address, block_order);
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
        PhysicalAddress.make(base_address.asInt() + mm.page_size),
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
    try std.testing.expectEqual(base_address.asInt(), one_page_addr.asInt());

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
