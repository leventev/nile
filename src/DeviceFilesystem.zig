const std = @import("std");
const vfs = @import("vfs.zig");
const Path = @import("Path.zig");

const DeviceFilesystem = @This();

const log = std.log.scoped(.devfs);

pub var skeleton: vfs.FileSystemSkeleton = .{
    .name = "devfs",
    .flags = .{
        .no_device = true,
    },
    .init = init,
    .read = read,
    .write = write,
};

fn read(internal_data: ?*anyopaque, inode: vfs.Inode, buff: []u8, offset: usize) !usize {
    const devfs: *DeviceFilesystem = @ptrCast(@alignCast(internal_data));
    // TODO: validate inode

    const dev = &devfs.inode_table[inode.asInt()];
    return dev.operations.read(dev.internal_data, buff, offset);
}

fn write(internal_data: ?*anyopaque, inode: vfs.Inode, buff: []const u8, offset: usize) !usize {
    const devfs: *DeviceFilesystem = @ptrCast(@alignCast(internal_data));
    // TODO: validate inode

    const dev = &devfs.inode_table[inode.asInt()];
    return dev.operations.write(dev.internal_data, buff, offset);
}

fn init(gpa: std.mem.Allocator, fs: *vfs.FileSystem) !?*anyopaque {
    const devfs = try gpa.create(DeviceFilesystem);
    devfs.fs = fs;
    devfs.inode_count = 0;

    return devfs;
}

fs: *vfs.FileSystem,

// TODO: dynamically allocate
inode_table: [100]Device,
inode_count: usize,

pub const Device = struct {
    operations: *const Operations,
    internal_data: *anyopaque,

    pub const Operations = struct {
        // TODO: errors
        read: *const fn (private_data: *anyopaque, buff: []u8, offset: usize) usize,
        write: *const fn (private_data: *anyopaque, buff: []const u8, offset: usize) usize,
    };
};

pub fn create(
    self: *DeviceFilesystem,
    path: []const u8,
    operations: *const Device.Operations,
    internal_data: *anyopaque,
) !void {
    const inode = self.inode_count;
    var path_walker = try Path.fromStringWithoutSlash(path);

    var current_dir = &self.fs.fs_cache.root_directory;
    while (path_walker.next()) |path_element| {
        const is_last_component = path_walker.reachedEnd();

        const dir_entry_ptr = current_dir.lookup(path_element);
        if (is_last_component) {
            try current_dir.create(path_element, .{ .regular = .{ .data = &.{} } });
        } else {
            const dir_entry = dir_entry_ptr.* orelse return error.InvalidPath;
            switch (dir_entry.data) {
                .regular => return error.EntryNotFound,
                .directory => |*dir| current_dir = dir,
            }
        }
    }

    self.inode_table[inode] = .{
        .operations = operations,
        .internal_data = internal_data,
    };
}
