const std = @import("std");

path: []const u8,
position: usize,

const Path = @This();

// TODO: handle paths containing invalid characters like '\0'

/// Create a Path from a string. The path can't be empty or start with /.
/// e.g. directory/another_directory/file
pub fn fromStringWithoutSlash(path: []const u8) error{InvalidPath}!Path {
    if (path.len == 0 or path[0] == '/') return error.InvalidPath;
    return Path{ .path = path, .position = 0 };
}

/// Create a Path from a string. The path can't be empty and must start with a /.
/// e.g. /directory/another_directory/file
pub fn fromStringWithSlash(path: []const u8) error{InvalidPath}!Path {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    return Path{ .path = path, .position = 1 };
}

pub fn next(self: *Path) ?[]const u8 {
    if (self.reachedEnd()) return null;

    // TODO: VALIDATE PATH
    const next_slash = std.mem.indexOfScalarPos(u8, self.path, self.position, '/') orelse self.path.len;

    const path_segment = self.path[self.position..next_slash];
    self.position = @min(next_slash + 1, self.path.len);
    return path_segment;
}

pub fn alreadyTraversed(self: *Path) []const u8 {
    return if (self.reachedEnd() or self.position <= 1)
        self.path[0..self.position]
    else
        self.path[0 .. self.position - 1];
}

pub fn reachedEnd(self: *Path) bool {
    return self.position == self.path.len;
}
