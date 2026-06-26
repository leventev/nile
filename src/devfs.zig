const std = @import("std");
const vfs = @import("vfs.zig");

pub const DeviceFsOperations = struct {
    // TODO: errors
    read: *const fn (private_data: *anyopaque, buff: []u8, offset: u8) usize,
    write: *const fn (private_data: *anyopaque, buff: []u8, offset: u8) usize,
};

pub var device_file_system_skeleton: vfs.FileSystemSkeleton = .{
    .name = "devfs",
    .flags = .{
        .no_device = true,
    },
    .init = init,
};

fn init(gpa: std.mem.Allocator, fs: *vfs.FileSystem) !?*anyopaque {
    const devfs = try gpa.create(DeviceFileSystem);
    devfs.fs = fs;

    return devfs;
}

pub const DeviceFileSystem = struct {
    fs: *vfs.FileSystem,

    pub fn create(
        self: *DeviceFileSystem,
        path: []const u8,
        operations: *DeviceFsOperations,
    ) void {
        _ = self;
        _ = path;
        _ = operations;
    }
};
