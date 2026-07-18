const std = @import("std");
const vfs = @import("vfs.zig");

pub fn init(_: std.mem.Allocator, _: *vfs.FileSystem) vfs.FileSystemError!?*anyopaque {
    return null;
}

pub var ram_file_system: vfs.FileSystemSkeleton = .{
    .name = "ramfs",
    .flags = .{
        .no_device = true,
        .has_page_cache = true,
    },
    .init = init,
    .read = null,
    .write = null,
};
