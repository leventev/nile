const std = @import("std");
const buddy_allocator = @import("buddy_allocator.zig");
const mm = @import("mm.zig");

const PhysicalAddress = mm.PhysicalAddress;
const VirtualAddress = mm.VirtualAddress;

/// Data about a slab used by a SlabCache. Each slab has a SlabDescriptor at the start of its
/// memory followed by the 'next list' which tracks the order in which the objects will be
/// allocated. The objects are allocated from the remaining memory space.
const SlabDescriptor = struct {
    /// Linked List node
    list_node: std.DoublyLinkedList.Node,

    /// The number of free objects in the slab
    free_object_count: usize,

    /// The index of the first free object, end_of_list if the slab is full
    first_free_obj_idx: ObjectIndex,

    const ObjectIndexType = u16;
    const ObjectIndex = enum(u16) { end_of_list = std.math.maxInt(ObjectIndexType), _ };

    /// Returns a slice to the 'next list'. It's located right after the SlabDescriptor
    /// and its length is the number of objects per slab.
    ///
    /// The list is similar to a linked list except the array entries contain indices
    /// to the next free object.
    fn next_list(self: *SlabDescriptor, obj_per_slab: usize) []ObjectIndex {
        const addr: [*]ObjectIndex = @ptrCast(@as([*]SlabDescriptor, @ptrCast(self)) + 1);
        return addr[0..obj_per_slab];
    }

    /// Allocates an object from the slab. The caller must make sure the slab has free objects
    /// available and that obj_per_slab, obj_size are correct.
    fn alloc(
        self: *SlabDescriptor,
        obj_per_slab: usize,
        obj_size: usize,
        obj_alignment_log: u5,
    ) VirtualAddress {
        std.debug.assert(self.free_object_count > 0);

        const object_id = self.first_free_obj_idx;
        if (object_id == .end_of_list)
            @panic("Slab should have free objects but the 'next list' is empty");

        const object_id_int = @intFromEnum(object_id);
        // pop the head of the 'next list'
        const list = self.next_list(obj_per_slab);
        self.first_free_obj_idx = list[object_id_int];
        self.free_object_count -= 1;

        // align the first object properly
        const obj_alignment = std.math.shl(usize, 1, obj_alignment_log);
        const list_end: usize = @intFromPtr(list.ptr + list.len);
        const list_end_align_rem = list_end % obj_alignment;
        const gap = if (list_end_align_rem > 0) (obj_alignment - list_end_align_rem) else 0;
        const objs_start = list_end + gap;

        std.log.info("next list: {X} list_end: {X} size: {} align: {} objs_start: {X}", .{
            @intFromPtr(list.ptr),
            list_end,
            obj_size,
            obj_alignment,
            objs_start,
        });
        return .make(objs_start + object_id_int * obj_size);
    }

    /// Frees an object. The caller must make sure that obj_per_slab, obj_size are correct.
    fn free(
        self: *SlabDescriptor,
        obj_addr: VirtualAddress,
        obj_per_slab: usize,
        obj_size: usize,
        obj_alignment_log: u5,
    ) void {
        const list = self.next_list(obj_per_slab);
        // align the first object properly
        const obj_alignment = std.math.shl(usize, 1, obj_alignment_log);
        const list_end: usize = @intFromPtr(list.ptr + list.len);
        const list_end_align_rem = list_end % obj_alignment;
        const gap = if (list_end_align_rem > 0) (obj_alignment - list_end_align_rem) else 0;
        const objs_start = list_end + gap;

        std.debug.assert(obj_addr > objs_start);
        const obj_id = (obj_addr - objs_start) / obj_size;
        std.debug.assert(obj_id < obj_per_slab);

        // prepend the 'next list' with the freed object's id
        // this way the most recently freed object will be the first to be allocated again,
        // increasing the chance that its in a loaded cacheline
        list[@intFromEnum(obj_id)] = self.first_free_obj_idx;
        self.first_free_obj_idx = obj_id;
        self.free_object_count += 1;
    }
};

/// Descriptor for a cache of objects or fixed-sized buffers.
///
/// The phyiscal memory used is organized into slabs which are
/// 2^slab_block_order contiguous pages allocated by the buddy allocator.
/// The slabs are stored in 3 doubly linked lists based on their state:
/// - unused
/// - partially used
/// - full
///
/// When allocating partially filled slabs are prioritized and the unused slabs
/// are only used when there are no partially used slabs left.
const SlabCache = struct {
    /// The name of the cache
    name: []const u8,

    /// The order of the blocks that are allocated for slabs, a slab is 2^slab_block_order pages
    slab_block_order: usize,

    /// The size of the objects in bytes
    object_size: usize,

    /// List of slabs with zero allocated objects
    unused_slabs: std.DoublyLinkedList,

    /// List of slabs that have both allocated and free objects
    partial_slabs: std.DoublyLinkedList,

    /// List of slabs with zero free objects
    full_slabs: std.DoublyLinkedList,

    /// The number of all allocated and free objects
    total_object_count: usize,

    /// The number of all free objects
    free_object_count: usize,

    /// The number of objects that fit inside a slab.
    /// Calculating this is not as simple as (slab byte size)/(object byte size) since
    /// the slab descriptor and the 'next list' are stored on-slab.
    objects_per_slab: usize,

    /// The required alignment of objects. In a slab if the address of the end of the 'next list'
    /// is not divisible by (1 << alignment_log) then the next aligned address is the address
    /// of the first object.
    /// It is assumed that the object_size is a multiple of (1 << alignment_log).
    alignment_log: u5,

    /// Linked list node
    list_node: std.DoublyLinkedList.Node,

    /// Allocate a new slab and add it to the unused slabs list
    fn grow(self: *SlabCache) buddy_allocator.BuddyAllocatorError!void {
        // TODO: on 32bit we cant map the entire physical address space so we will have to
        // find a different way to do this
        const phys_addr = try buddy_allocator.allocBlock(self.slab_block_order);
        const virt_addr = mm.physicalToHHDMAddress(phys_addr);

        var slab_descriptor: *SlabDescriptor = @ptrFromInt(virt_addr.asInt());
        slab_descriptor.free_object_count = self.objects_per_slab;

        // 'next list'
        slab_descriptor.first_free_obj_idx = @enumFromInt(0);
        const list = slab_descriptor.next_list(self.objects_per_slab);
        for (0..list.len - 1) |i| list[i] = @enumFromInt(i + 1);
        list[list.len - 1] = .end_of_list;

        self.unused_slabs.append(&slab_descriptor.list_node);
        self.free_object_count += self.objects_per_slab;
        self.total_object_count += self.objects_per_slab;
    }

    /// Allocate a new object. Partially filled slabs are prioritized over unused slabs.
    /// If no unused slabs are available a new slab is allocated with the buddy allocator.
    fn alloc(self: *SlabCache) buddy_allocator.BuddyAllocatorError!VirtualAddress {
        if (self.partial_slabs.first) |first_slab| {
            var slab_descriptor: *SlabDescriptor = @fieldParentPtr("list_node", first_slab);
            const addr = slab_descriptor.alloc(
                self.objects_per_slab,
                self.object_size,
                self.alignment_log,
            );

            if (slab_descriptor.free_object_count == 0) {
                self.partial_slabs.remove(&slab_descriptor.list_node);
                self.full_slabs.append(&slab_descriptor.list_node);
            }

            return addr;
        }

        const unused_slab = self.unused_slabs.pop() orelse blk: {
            try self.grow();
            break :blk self.unused_slabs.pop() orelse
                @panic("Unused slabs is empty after growing");
        };
        var slab_descriptor: *SlabDescriptor = @fieldParentPtr("list_node", unused_slab);
        const addr = slab_descriptor.alloc(
            self.objects_per_slab,
            self.object_size,
            self.alignment_log,
        );
        self.partial_slabs.append(&slab_descriptor.list_node);
        return addr;
    }
    fn free(self: *SlabCache, address: VirtualAddress) void {
        _ = self;
        _ = address;
    }
};

/// Calculates the number of objects that fit inside a slab
fn objectsPerSlab(
    slab_block_order: usize,
    obj_size: usize,
    obj_alignment_log: u5,
) usize {
    const slab_size = std.math.shl(usize, 1, slab_block_order) * mm.page_size;
    const obj_alignment = std.math.shl(usize, 1, obj_alignment_log);

    // make a rough estimate first without taking alignment into account
    const usable_slab_size = slab_size - @sizeOf(SlabDescriptor);
    const bytes_per_obj = @sizeOf(SlabDescriptor.ObjectIndex) + obj_size;
    var objects_per_slab = usable_slab_size / bytes_per_obj;
    const wastage = usable_slab_size % bytes_per_obj;

    const next_list_size = objects_per_slab * @sizeOf(SlabDescriptor.ObjectIndex);
    const list_end: usize = @sizeOf(SlabDescriptor) + next_list_size;
    const alignment_rem = list_end % obj_alignment;

    // if the end address of the 'next list' is not aligned then we have to skip a few bytes
    if (alignment_rem > 0) {
        const gap = obj_alignment - alignment_rem;
        // wastage is our allowance, if we need to skip more bytes than that then we need to
        // reduce the object size to free up more space
        if (gap > wastage) {
            // since obj_size >= (1 << obj_alignment_log) reducing the object count by 1
            // makes more than enough space for us to be able to align the first object
            objects_per_slab -= 1;
        }
    }

    return objects_per_slab;
}

var caches = std.DoublyLinkedList{};

var cache_cache_slab: SlabCache = blk: {
    const slab_block_order = 0;
    const object_size = @sizeOf(SlabCache);
    const object_alignment = std.math.log2_int(u5, @alignOf(SlabCache));

    break :blk SlabCache{
        .name = "cache-descriptor",
        .slab_block_order = slab_block_order,
        .unused_slabs = .{},
        .partial_slabs = .{},
        .full_slabs = .{},
        .free_object_count = 0,
        .total_object_count = 0,
        .list_node = .{},
        .object_size = object_size,
        .alignment_log = object_alignment,
        .objects_per_slab = objectsPerSlab(slab_block_order, object_size, object_alignment),
    };
};
var cache_cache = ObjectCache(SlabCache){
    .__slab_cache = &cache_cache_slab,
};

/// An object specific allocator, objects are preallocated resulting in faster allocations.
/// More space is reserved if the cache runs out of available objects.
/// TODO: Currently there is no way to shrink the cache.
pub fn ObjectCache(comptime T: type) type {
    return struct {
        const Self = @This();
        /// Internal slab allocator, this struct is used as a wrapper around it
        /// for nicer interface. Should not be accessed outside.
        __slab_cache: *SlabCache = undefined,

        /// Allocate a single T object
        pub fn alloc(self: Self) buddy_allocator.BuddyAllocatorError!*T {
            const addr: VirtualAddress = try self.__slab_cache.alloc();
            return @as(*T, @ptrFromInt(addr.asInt()));
        }

        /// Free a single T object
        pub fn free(self: Self, ptr: *T) void {
            const addr: VirtualAddress = .make(@intFromPtr(ptr));
            self.__slab_cache.free(addr);
        }

        /// Initializes the cache, can only be called after the buddy allocator has been initialized
        pub fn init(self: *Self) void {
            std.log.info("{} {} {}", .{ @sizeOf(SlabDescriptor), @alignOf(SlabDescriptor.ObjectIndex), @alignOf(T) });
            self.__slab_cache = cache_cache.alloc() catch @panic("Unable to allocate new cache");

            // TODO: come up with some kind of logic for assigning higher block orders
            const slab_block_order = 0;
            const obj_size = @sizeOf(T);
            const obj_alignment_log = std.math.log2_int(u5, @alignOf(T));
            self.__slab_cache.* = .{
                .name = @typeName(T) ++ "-cache",
                .slab_block_order = slab_block_order,
                .unused_slabs = .{},
                .partial_slabs = .{},
                .full_slabs = .{},
                .free_object_count = 0,
                .total_object_count = 0,
                .list_node = .{},
                .object_size = obj_size,
                .alignment_log = obj_alignment_log,
                .objects_per_slab = objectsPerSlab(slab_block_order, obj_size, obj_alignment_log),
            };
        }
    };
}

test "objects per slab" {
    // results calculated with the assumption that @sizeOf(SlabDescriptor) = 32
    // and @sizeOf(ObjectIndex) = 2

    const objects_per_slab_1 = objectsPerSlab(0, 8, 3);
    // (4096 - 32) / 10 = ~406.4
    // 'next list' end is 32 + 406 * 2 = 844 which is not aligned to 8 bytes,
    // next aligned address is 848 so we need 4 bytes
    // wastage for 406 objects is (4096 - 32) - 406 * 10 = 4
    // since we need 4 bytes and we have 4 bytes of allowance then 406 objects are possible
    try std.testing.expectEqual(406, objects_per_slab_1);

    const objects_per_slab_2 = objectsPerSlab(0, 32, 4);
    // (4096 - 32) / 34 = ~119.53
    // 'next list' end is 32 + 119 * 2 = 270 which is not aligned to 16 bytes,
    // next aligned address is 272 so we need 2 bytes
    // wastage for 119 objects is (4096 - 32) - 119 * 34 = 18
    // since we need 4 bytes and we have 18 bytes of allowance then 119 objects are possible
    try std.testing.expectEqual(119, objects_per_slab_2);

    const objects_per_slab_3 = objectsPerSlab(0, 128, 6);
    // (4096 - 32) / 130 = ~31.25
    // 'next list' end is 32 + 31 * 2 = 94 which is not aligned to 64 bytes,
    // next aligned address is 128 so we need 34 bytes
    // wastage for 31 objects is (4096 - 32) - 31 * 130 = 34
    // since we need 34 bytes and we have 34 bytes of allowance then 31 objects are possible
    try std.testing.expectEqual(31, objects_per_slab_3);
}
