const std = @import("std");
const arch = @import("../../arch/arch.zig");
const mm = @import("../mm.zig");

const order_count = 11;
const max_order = order_count - 1;

// TODO: find a better way to do this
const free_list_heap_size = 65535;
var free_list_heap: [free_list_heap_size]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&free_list_heap);
const free_list_allocator = fba.allocator();

const FreeBlock = struct {
    list_node: std.DoublyLinkedList.Node,
    block_addr: arch.PhysicalAddress,
};

const Order = struct {
    list: std.DoublyLinkedList,
    free_block_count: usize,

    fn orderedAdd(self: *Order, block_addr: arch.PhysicalAddress) void {
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
            const block_addr = arch.PhysicalAddress.make(block_page_idx * mm.page_size);

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

pub fn init(regions: []const mm.MemoryRegion) void {
    for (regions) |region| {
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
}

test "init" {
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
