const std = @import("std");
const Module = @import("../../Module.zig");
const Path = @import("../../Path.zig");
const slab_allocator = @import("../../mem/slab_allocator.zig");
const vfs = @import("../../vfs.zig");

pub fn init(_: std.mem.Allocator, _: *vfs.FileSystem) vfs.FileSystemError!?*anyopaque {
    return null;
}

pub const module: Module = .{
    .name = "ramfs",
    .module_type = .{
        .fs = &ram_file_system,
    },
};

var ram_file_system: vfs.FileSystemSkeleton = .{
    .name = "ramfs",
    .flags = .{
        .no_device = true,
        .has_page_cache = true,
    },
    .init = init,
    .read = null,
    .write = null,
};
