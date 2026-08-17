const std = @import("std");
const vfs = @import("vfs.zig");
const Path = @import("Path.zig");
const Process = @import("Process.zig");
const processes = @import("processes.zig");
const core = @import("core");
const MessageType = core.message.MessageType;

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

    const written_buff = MessageType.uint32.writeWithMagic(
        @intCast(processes.process_count),
        buff,
    );
    return if (written_buff) |b| b.len else 0;
}

fn init(gpa: std.mem.Allocator, fs: *vfs.FileSystem) !?*anyopaque {
    const procfs = try gpa.create(ProcessFilesystem);
    procfs.fs = fs;
    procfs.inode_count = 0;
    procfs.gpa = gpa;

    procfs.create("processcount", null, &.{ .read = processCount }) catch @panic("TODO");

    return procfs;
}

gpa: std.mem.Allocator,
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
            const path_element_copied = try self.gpa.dupe(u8, path_element);
            try current_dir.createDirectory(path_element_copied, .fromInt(inode));
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
            const path_element_copied = try self.gpa.dupe(u8, path_element);
            try current_dir.createRegularUnique(
                path_element_copied,
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

fn addToProcessSubdir(
    self: *ProcessFilesystem,
    process: *Process,
    regular_name: []const u8,
    operations: *const vfs.FileSystemSkeleton.Operations,
) !void {
    var buff: [512]u8 = undefined;
    const name = try std.fmt.bufPrint(&buff, "{}/{s}", .{ @intFromEnum(process.id), regular_name });
    try self.create(name, process, operations);
}

pub fn addProcess(self: *ProcessFilesystem, process: *Process) !void {
    var buff: [128]u8 = undefined;
    const dir_name = try std.fmt.bufPrint(&buff, "{}", .{@intFromEnum(process.id)});
    // TODO: remove process subdir if it gets killed, decide what to do with open files
    self.createDirectory(dir_name) catch return;
    try self.addToProcessSubdir(process, "child_exitcode", &.{ .read = exitCodeRead });
}

fn exitCodeRead(
    process_ptr: ?*anyopaque,
    _: vfs.Inode,
    buff: []u8,
    _: usize,
) vfs.FileSystemError!usize {
    const process: *Process = @ptrCast(@alignCast(process_ptr orelse unreachable));
    if (buff.len < @sizeOf(isize) or @intFromPtr(buff.ptr) % @sizeOf(isize) != 0) return 0;

    process.last_child_exit_code_semaphore.sub();

    const ptr: *isize = @ptrCast(@alignCast(buff.ptr));
    ptr.* = process.last_child_exit_code orelse unreachable;

    return @sizeOf(isize);
}
