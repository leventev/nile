const std = @import("std");
const arch = @import("../../arch/arch.zig");
const mm = @import("../mm.zig");

const PhysicalAddress = arch.PhysicalAddress;

const order_count = 11;
const max_order = order_count - 1;

// TODO: find a better way to do this
const free_list_heap_size = 65535;
var free_list_heap: [free_list_heap_size]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&free_list_heap);
const free_list_allocator = fba.allocator();

const FreeBlock = struct {
    list_node: std.DoublyLinkedList.Node,
    block_addr: PhysicalAddress,
};

const Order = struct {
    list: std.DoublyLinkedList,
    free_block_count: usize,

    fn orderedAdd(self: *Order, block_addr: PhysicalAddress) void {
        const new_block = free_list_allocator.create(FreeBlock) catch {
            @panic("Buddy Allocator ran out of heap space");
        };
        new_block.block_addr = block_addr;
        new_block.list_node = .{};

        // TODO: possibly clean this up and get rid of the special cases
        const first_node = self.list.first;
        if (first_node) |first| {
            const block: *FreeBlock = @fieldParentPtr("list_node", first);
            if (block_addr.asInt() < block.block_addr.asInt()) {
                self.list.prepend(&new_block.list_node);
            } else {
                var list_node = first_node;
                while (list_node) |node| {
                    const next_list_node = node.next;
                    if (next_list_node) |next_node| {
                        const next_block: *FreeBlock = @fieldParentPtr("list_node", next_node);
                        if (block_addr.asInt() < next_block.block_addr.asInt()) {
                            self.list.insertAfter(node, &new_block.list_node);
                            break;
                        }
                    } else {
                        self.list.insertAfter(node, &new_block.list_node);
                    }

                    list_node = next_list_node;
                }
            }
        } else {
            self.list.prepend(&new_block.list_node);
        }

        self.free_block_count += 1;
    }
};

var orders: [order_count]Order = [_]Order{Order{ .free_block_count = 0, .list = .{} }} ** order_count;

fn addBlocksFromRegion(start_page_idx: usize, page_count: usize) void {
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

            orders[order].orderedAdd(block_addr);
        }

        const last_block_end_page_idx = next_aligned_page_idx + block_count * block_size_in_pages;

        // 4. add remaining leading and trailing regions as well
        // the maximum depth of recursion is less than order_count

        if (next_aligned_page_idx != start_page_idx) {
            const leading_region_page_idx = start_page_idx;
            const leading_region_page_count = next_aligned_page_idx - start_page_idx;
            addBlocksFromRegion(leading_region_page_idx, leading_region_page_count);
        }

        if (last_block_end_page_idx != end_page_idx) {
            const trailing_region_page_idx = last_block_end_page_idx;
            const trailing_region_page_count = end_page_idx - last_block_end_page_idx;
            addBlocksFromRegion(trailing_region_page_idx, trailing_region_page_count);
        }

        return;
    }

    // if the smallest possible order is 0th then we just add all pages to the free list

    for (0..page_count) |i| {
        const block_page_idx = start_page_idx + i;
        const block_addr = arch.PhysicalAddress.make(block_page_idx * mm.page_size);
        orders[0].orderedAdd(block_addr);
    }
}

pub const BuddyAllocatorError = error{
    InvalidOrder,
    OutOfMemory,
};

/// Returns whether the specified block was in the list
fn removeBlock(order: usize, address: PhysicalAddress) bool {
    var list_node = orders[order].list.first;
    while (list_node) |node| : (list_node = node.next) {
        const block: *FreeBlock = @fieldParentPtr("list_node", node);
        if (block.block_addr == address) {
            orders[order].list.remove(node);
            orders[order].free_block_count -= 1;
            return true;
        }
    }

    return false;
}

pub fn allocBlock(desired_order: usize) BuddyAllocatorError!PhysicalAddress {
    if (desired_order > max_order) return error.InvalidOrder;

    // find the lowest order that has a free block
    var order = desired_order;
    while (orders[order].free_block_count == 0) : (order += 1) {}
    // for simplicity's sake we always try to select the leftmost block
    // to bias lower addresses hence popFirst() instead pop()
    if (orders[order].list.popFirst()) |list_node| {
        const block: *FreeBlock = @fieldParentPtr("list_node", list_node);
        // when we split an N order block into two N-1 order blocks we always select the
        // left N-1 block so the address always stays the same
        const selected_block_addr: PhysicalAddress = block.block_addr;
        free_list_allocator.destroy(block);
        orders[order].free_block_count -= 1;

        // keep splitting the blocks until we reach the desired order
        while (order > desired_order) {
            order -= 1;
            const block_size_in_pages = std.math.shl(usize, 1, order);
            const offset = block_size_in_pages * mm.page_size;
            const right_block_addr = PhysicalAddress.make(selected_block_addr.asInt() + offset);
            orders[order].orderedAdd(right_block_addr);
        }

        return selected_block_addr;
    } else return error.OutOfMemory;
}

pub fn deallocBlock(block_address: PhysicalAddress, block_order: usize) void {
    std.debug.assert(block_order <= max_order);
    var order = block_order;
    var address = block_address;

    // we try to coalesce the specified block and its buddy
    while (order <= max_order) : (order += 1) {
        // buddy's address can be calculated by XOR-ing with the size
        const block_size = std.math.shl(usize, 1, order) * mm.page_size;
        const buddy_address = PhysicalAddress.make(address.asInt() ^ block_size);

        // if the buddy is free then we remove it and move on to the next order
        const buddy_is_free = removeBlock(order, buddy_address);
        if (!buddy_is_free) {
            break;
        }

        address = .make(@min(address.asInt(), buddy_address.asInt()));
    }

    orders[order].orderedAdd(address);
}

pub fn init(regions: []const mm.MemoryRegion) void {
    var total_frames: usize = 0;

    for (regions) |region| {
        const frame_count: usize = regions.size / mm.frame_size;
        total_frames += frame_count;

        // TODO: convert the fields of mm.MemoryRegion to be page indices instead of absolute addresses
        const start_page_index: usize = region.start / mm.page_size;
        const page_count: usize = region.size / mm.page_size;
        addBlocksFromRegion(start_page_index, page_count);
    }

    for (0.., orders) |i, order| {
        std.log.info("Order #{}: {} free blocks", .{ i, order.free_block_count });
        var block_list_node = order.list.first;
        while (block_list_node) |list_node| : (block_list_node = list_node.next) {
            const block: *FreeBlock = @fieldParentPtr("list_node", list_node);
            std.log.info("addr: {x}", .{block.block_addr.asInt()});
        }
    }

    std.log.info("Buddy allocator allocator initialized with {} frames ({} KiB) available", .{
        total_frames,
        total_frames * 4,
    });
}

// we need to reset orders and fba every test because zig retains global state between tests

test "init" {
    orders = [_]Order{Order{ .free_block_count = 0, .list = .{} }} ** order_count;
    fba.reset();

    const start: usize = 0x3D0_000;
    const end: usize = 0xA0E_000;
    const start_page_idx = start / mm.page_size;
    const end_page_idx = end / mm.page_size;
    const page_count = end_page_idx - start_page_idx;

    // the counts were calculated by hand
    addBlocksFromRegion(start_page_idx, page_count);
    try std.testing.expectEqual(1, orders[10].free_block_count);
    try std.testing.expectEqual(1, orders[9].free_block_count);
    try std.testing.expectEqual(1, orders[5].free_block_count);
    try std.testing.expectEqual(1, orders[4].free_block_count);
    try std.testing.expectEqual(1, orders[3].free_block_count);
    try std.testing.expectEqual(1, orders[2].free_block_count);
    try std.testing.expectEqual(1, orders[1].free_block_count);

    try std.testing.expectEqual(0, orders[0].free_block_count);
    try std.testing.expectEqual(0, orders[6].free_block_count);
    try std.testing.expectEqual(0, orders[7].free_block_count);
    try std.testing.expectEqual(0, orders[8].free_block_count);
}

test "alloc" {
    orders = [_]Order{Order{ .free_block_count = 0, .list = .{} }} ** order_count;
    fba.reset();

    // add 1 block of the highest order
    const base_address = PhysicalAddress.make(1 * 1024 * mm.page_size);
    orders[10].orderedAdd(base_address);

    // they should be equal because of the lower address bias of the allocator
    const one_page_addr = try allocBlock(0);
    try std.testing.expectEqual(base_address, one_page_addr);
    const one_page_addr_2 = try allocBlock(0);
    try std.testing.expectEqual(PhysicalAddress.make((1 * 1024 + 1) * mm.page_size), one_page_addr_2);

    try std.testing.expectEqual(0, orders[10].free_block_count);
    try std.testing.expectEqual(1, orders[9].free_block_count);
    try std.testing.expectEqual(1, orders[8].free_block_count);
    try std.testing.expectEqual(1, orders[7].free_block_count);
    try std.testing.expectEqual(1, orders[6].free_block_count);
    try std.testing.expectEqual(1, orders[5].free_block_count);
    try std.testing.expectEqual(1, orders[4].free_block_count);
    try std.testing.expectEqual(1, orders[3].free_block_count);
    try std.testing.expectEqual(1, orders[2].free_block_count);
    try std.testing.expectEqual(1, orders[1].free_block_count);
    try std.testing.expectEqual(0, orders[0].free_block_count);
    try std.testing.expectEqual(base_address.asInt(), one_page_addr.asInt());

    deallocBlock(one_page_addr, 0);
    deallocBlock(one_page_addr_2, 0);
    try std.testing.expectEqual(1, orders[10].free_block_count);
    try std.testing.expectEqual(0, orders[9].free_block_count);
    try std.testing.expectEqual(0, orders[8].free_block_count);
    try std.testing.expectEqual(0, orders[7].free_block_count);
    try std.testing.expectEqual(0, orders[6].free_block_count);
    try std.testing.expectEqual(0, orders[5].free_block_count);
    try std.testing.expectEqual(0, orders[4].free_block_count);
    try std.testing.expectEqual(0, orders[3].free_block_count);
    try std.testing.expectEqual(0, orders[2].free_block_count);
    try std.testing.expectEqual(0, orders[1].free_block_count);
    try std.testing.expectEqual(0, orders[0].free_block_count);
}
