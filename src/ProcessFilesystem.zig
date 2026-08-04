const std = @import("std");
const vfs = @import("vfs.zig");
const Path = @import("Path.zig");
const Process = @import("Process.zig");
const processes = @import("processes.zig");

const ProcessFilesystem = @This();

const log = std.log.scoped(.devfs);

pub var skeleton: vfs.FileSystemSkeleton = .{
    .name = "procfs",
    .flags = .{
        .no_device = true,
        .has_page_cache = false,
    },
    .init = init,
    .operations = null,
};

fn processCount(
    _: ?*anyopaque,
    _: vfs.Inode,
    buff: []u8,
    _: usize,
) vfs.FileSystemError!usize {
    if (buff.len < @sizeOf(usize) or @intFromPtr(buff.ptr) % @sizeOf(usize) != 0) return 0;

    const ptr: *usize = @ptrCast(@alignCast(buff.ptr));
    ptr.* = processes.process_count;
    return @sizeOf(usize);
}

fn init(gpa: std.mem.Allocator, fs: *vfs.FileSystem) !?*anyopaque {
    const procfs = try gpa.create(ProcessFilesystem);
    procfs.fs = fs;
    procfs.inode_count = 0;

    procfs.create("processcount", null, &.{
        .read = processCount,
    }) catch @panic("TODO");

    return procfs;
}

fs: *vfs.FileSystem,
inode_count: u32,

fn createDirectory(self: *ProcessFilesystem, path: []const u8) !void {
    const inode = self.inode_count;
    var path_walker = try Path.fromStringWithoutSlash(path);

    var current_dir = &self.fs.fs_cache.root_directory;
    while (path_walker.next()) |path_element| {
        const is_last_component = path_walker.reachedEnd();

        const dir_entry_ptr = current_dir.lookup(path_element);
        if (is_last_component) {
            try current_dir.createDirectory(path_element, inode);
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

pub fn create(
    self: *ProcessFilesystem,
    path: []const u8,
    internal_data: ?*anyopaque,
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
