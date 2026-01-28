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

    const ObjectIndex = enum(u16) { end_of_list = std.math.maxInt(u16), _ };

    /// Returns a slice to the 'next list'. It's located right after the SlabDescriptor
    /// and its length is the number of objects per slab.
    ///
    /// The list is similar to a linked list except the array entries contain indices
    /// to the next free object.
    fn next_list(self: *SlabDescriptor, obj_per_slab: usize) []ObjectIndex {
        const addr: *ObjectIndex = @ptrCast(@as([*]SlabDescriptor, @ptrCast(self)) + 1);
        const list: []ObjectIndex = addr[0..obj_per_slab];
        return list;
    }

    /// Allocates an object from the slab. The caller must make sure the slab has free objects
    /// available and that obj_per_slab, obj_size are correct.
    fn alloc(self: *SlabDescriptor, obj_per_slab: usize, obj_size: usize) VirtualAddress {
        std.debug.assert(self.free_object_count > 0);

        const object_id = self.first_free_obj_idx;
        if (object_id == .end_of_list)
            @panic("Slab should have free objects but the 'next list' is empty");

        // pop the head of the 'next list'
        const list = self.next_list(obj_per_slab);
        self.first_free_obj_idx = list[@intFromEnum(object_id)];
        self.free_object_count -= 1;

        const objs_start: usize = @intFromPtr(list.ptr + list.len);

        return objs_start + object_id * obj_size;
    }

    /// Frees an object. The caller must make sure that obj_per_slab, obj_size are correct.
    fn free(
        self: *SlabDescriptor,
        obj_addr: VirtualAddress,
        obj_per_slab: usize,
        obj_size: usize,
    ) void {
        const list = self.next_list(obj_per_slab);
        const objs_start: usize = @intFromPtr(list.ptr + list.len);

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
pub const SlabCache = struct {
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
        slab_descriptor.first_free_obj_idx = 0;
        const list = slab_descriptor.next_list(self.objects_per_slab);
        for (0..list.len - 1) |i| list[i] = i + 1;
        list[list.len] = .end_of_list;

        self.unused_slabs.append(&slab_descriptor);
        self.free_object_count += self.objects_per_slab;
    }

    /// Allocate a new object. Partially filled slabs are prioritized over unused slabs.
    /// If no unused slabs are available a new slab is allocated with the buddy allocator.
    pub fn alloc(self: *SlabCache) buddy_allocator.BuddyAllocatorError!VirtualAddress {
        if (self.partial_slabs.first) |first_slab| {
            var slab_descriptor: *SlabDescriptor = @fieldParentPtr("list_node", first_slab);
            const addr = slab_descriptor.alloc(self.objects_per_slab, self.object_size);

            if (slab_descriptor.free_object_count == 0) {
                self.partial_slabs.remove(&slab_descriptor.list_node);
                self.full_slabs.append(&slab_descriptor.list_node);
            }

            return addr;
        }

        const slab = self.unused_slabs.pop() orelse blk: {
            try self.grow();
            break :blk self.unused_slabs.pop() orelse
                @panic("Unused slabs is empty after growing");
        };

        var slab_descriptor: *SlabDescriptor = @fieldParentPtr("list_node", slab);
        const addr = slab_descriptor.alloc(self.objects_per_slab, self.object_size);

        self.partial_slabs.append(&slab_descriptor.list_node);

        return addr;
    }

    pub fn free(self: *SlabCache, address: VirtualAddress) void {
        _ = self;
        _ = address;
    }
};

var caches = std.DoublyLinkedList{};

var descriptor_cache = SlabCache{
    .name = "cache-descriptor",
    .slab_block_order = 0,
    .unused_slabs = .{},
    .partial_slabs = .{},
    .full_slabs = .{},
    .free_object_count = 0,
    .total_object_count = 0,
    .list_node = .{},
};

pub fn init() void {}
