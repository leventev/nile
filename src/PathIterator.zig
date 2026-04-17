const std = @import("std");

path: []const u8,
position: usize,

const PathIterator = @This();

// TODO: handle paths containing invalid characters like '\0'

/// Create a path iterator from a string. The path can't be empty or start with /.
/// e.g. directory/another_directory/file
pub fn fromString(path: []const u8) error{InvalidPath}!PathIterator {
    if (path.len == 0 or path[1] == '/') return error.InvalidPath;
    return PathIterator{ .path = path, .position = 0 };
}

pub fn next(self: *PathIterator) ?[]const u8 {
    if (self.reachedEnd()) return null;

    const next_slash = std.mem.indexOfScalarPos(u8, self.path, self.position, '/') orelse self.path.len;

    const path_segment = self.path[self.position..next_slash];
    self.position = @min(next_slash + 1, self.path.len);
    return path_segment;
}

pub fn reachedEnd(self: *PathIterator) bool {
    return self.position == self.path.len;
}
