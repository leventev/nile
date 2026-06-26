const std = @import("std");
const fs = @import("fs.zig");

pub const DeviceFsOperations = struct {
    // TODO: errors
    read: *const fn (private_data: *anyopaque, buff: []u8, offset: u8) usize,
    write: *const fn (private_data: *anyopaque, buff: []u8, offset: u8) usize,
};

pub var device_file_system_skeleton: fs.FileSystemSkeleton = .{
    .name = "devfs",
    .flags = .{
        .no_device = true,
    },
    .init = init,
};

fn init(gpa: std.mem.Allocator) !?*anyopaque {
    const devfs = try gpa.create(DeviceFileSystem);

    return devfs;
}

pub const DeviceFileSystem = struct {
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
