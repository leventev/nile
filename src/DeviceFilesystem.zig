const std = @import("std");
const vfs = @import("vfs.zig");
const Path = @import("Path.zig");

const DeviceFilesystem = @This();

const log = std.log.scoped(.devfs);

pub var skeleton: vfs.FileSystemSkeleton = .{
    .name = "devfs",
    .flags = .{
        .no_device = true,
        .has_page_cache = false,
    },
    .init = init,
    .operations = null,
};

fn init(gpa: std.mem.Allocator, fs: *vfs.FileSystem) !?*anyopaque {
    const devfs = try gpa.create(DeviceFilesystem);
    devfs.fs = fs;
    devfs.inode_count = 0;

    return devfs;
}

fs: *vfs.FileSystem,

// TODO: dynamically allocate
inode_count: u32,

pub fn create(
    self: *DeviceFilesystem,
    path: []const u8,
    internal_data: *anyopaque,
    operations: *const vfs.FileSystemSkeleton.Operations,
) !void {
    const inode = self.inode_count;
    var path_walker = try Path.fromStringWithoutSlash(path);

    var current_dir = &self.fs.fs_cache.root_directory;
    while (path_walker.next()) |path_element| {
        const is_last_component = path_walker.reachedEnd();

        const dir_entry_ptr = current_dir.lookup(path_element);
        if (is_last_component) {
            try current_dir.createRegularUnique(
                path_element,
                .fromInt(inode),
                internal_data,
                operations,
            );
        } else {
            const dir_entry = dir_entry_ptr.* orelse return error.InvalidPath;
            switch (dir_entry.filetype) {
                .regular => return error.EntryNotFound,
                .directory => current_dir = dir_entry.directory(),
            }
        }
    }

    self.inode_count += 1;
}
