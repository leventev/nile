const std = @import("std");
const slab_allocator = @import("mem/slab_allocator.zig");
const buddy_allocator = @import("mem/buddy_allocator.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const sync = @import("sync.zig");

const PageCache = @This();

/// The root table of the radix tree. It is changed when adding a new level.
root: *Table,

/// How many levels there are in total.
/// The number of total pages is pow(Table.child_count, level_count).
level_count: usize,

/// Lock
spinlock: sync.Spinlock,

pub fn getPage(self: *PageCache, page_index: usize, allocate: bool) !mm.VirtualAddress {
    std.debug.assert(page_index <= self.totalPageCount());

    const bits_per_level = std.math.log2(Table.child_count);
    const base_mask = std.math.shl(usize, 1, bits_per_level) - 1;

    var table = self.root;

    // 0th level is the innermost one
    var level = self.level_count - 1;
    while (true) {
        const bit_offset = bits_per_level * level;
        const index = std.math.shr(usize, page_index, bit_offset) & base_mask;

        if (level == 0) {
            const page_ptr = table.children[index] orelse blk: {
                if (!allocate) @panic("Page cache entry is not allocated");
                const new_page_phys = try buddy_allocator.allocBlock(0);
                const new_page = mm.physicalToVirtual(new_page_phys).asPtr(*anyopaque);
                table.children[index] = new_page;
                break :blk new_page;
            };

            return .fromInt(@intFromPtr(page_ptr));
        }

        table = if (table.children[index]) |ptr| @as(*Table, @ptrCast(@alignCast(ptr))) else blk: {
            if (!allocate) @panic("Page cache entry is not allocated");
            const new_table = try Table.cache.alloc();
            table.children[index] = new_table;
            break :blk new_table;
        };

        level -= 1;
    }
}

/// Returns the total number of pages.
pub fn totalPageCount(self: *PageCache) usize {
    return std.math.pow(usize, Table.child_count, self.level_count);
}

const max_level = 4;

/// Adds a level to the page cache.
pub fn expandLocked(self: *PageCache) error{OutOfMemory}!void {
    std.debug.assert(self.level_count < max_level);
    const new_root = try Table.cache.alloc();

    new_root.children[0] = self.root;
    for (1..Table.child_count) |i|
        new_root.children[i] = null;

    self.root = new_root;
    self.level_count += 1;
}

pub fn setup(self: *PageCache) error{OutOfMemory}!void {
    const root_table = try PageCache.Table.cache.alloc();
    for (0..PageCache.Table.child_count) |i|
        root_table.children[i] = null;

    self.* = .{
        .level_count = 1,
        .root = root_table,
        .spinlock = .unlocked,
    };
}

/// A node in the page cache radix tree.
const Table = struct {
    // TODO: dirty flags
    // dirty: std.bit_set.IntegerBitSet(child_count),

    children: [child_count]?*anyopaque,

    const child_count = @bitSizeOf(usize);
    var cache: slab_allocator.ObjectCache(Table) = undefined;
};

pub fn init() void {
    PageCache.Table.cache = slab_allocator.createObjectCache(PageCache.Table);
}
