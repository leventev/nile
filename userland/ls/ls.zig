const std = @import("std");
const sys = @import("sys");
const core = sys.core;

pub fn main() void {
    const root_dir_fd = sys.openat(null, "/test_dir", 0, 0) catch sys.exit(-1);

    var buffer: [512]u8 align(@alignOf(core.fs.DirectoryEntryHeader)) = undefined;
    var dir_iter = sys.readDirectory(root_dir_fd, &buffer) catch sys.exit(-1);

    while (dir_iter.next()) |dir_ent| {
        _ = sys.write(sys.stdout_fd, dir_ent.name) catch sys.exit(-1);
        _ = sys.write(sys.stdout_fd, " ") catch sys.exit(-1);
    }

    _ = sys.write(sys.stdout_fd, "\n") catch sys.exit(-1);
}
