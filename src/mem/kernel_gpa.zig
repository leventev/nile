const std = @import("std");
const slab_allocator = @import("slab_allocator.zig");

const log = std.log.scoped(.gpa);

const sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };

pub const KernelGPA = struct {
    caches: [sizes.len]slab_allocator.FixedSizedCache = undefined,

    pub fn init(self: *KernelGPA) void {
        for (sizes, 0..) |size, i| {
            slab_allocator.initFixedBufferCache(&self.caches[i], size);
        }
    }

    pub fn allocator(self: *KernelGPA) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;

    const kernel_gpa: *KernelGPA = @ptrCast(@alignCast(ptr));

    for (sizes, 0..) |cache_size, i| {
        if (size > cache_size) continue;

        if (alignment.toByteUnits() > cache_size) {
            log.warn("alignment is bigger than size, returning null", .{});
            return null;
        }

        return @ptrCast(kernel_gpa.caches[i].alloc() catch return null);
    }

    return null;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    _ = alignment;

    const kernel_gpa: *KernelGPA = @ptrCast(@alignCast(ptr));

    var i = sizes.len;
    while (i > 0) {
        i -= 1;
        if (memory.len > sizes[i]) continue;

        kernel_gpa.caches[i].free(memory.ptr);
        return;
    }

    log.warn("freeing buffer with an impossible size: {}", .{memory.len});
}

fn resize(
    ptr: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = alignment;
    _ = ret_addr;

    const kernel_gpa: *KernelGPA = @ptrCast(@alignCast(ptr));
    _ = kernel_gpa;

    var i = sizes.len;
    while (i > 0) {
        i -= 1;
        if (memory.len > sizes[i]) continue;

        return new_len <= sizes[i];
    }

    unreachable;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;

    return null;
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = allocate,
    .free = free,
    .resize = resize,
    .remap = remap,
};
