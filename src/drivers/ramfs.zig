const std = @import("std");
const PathIterator = @import("../PathIterator.zig");
const slab_allocator = @import("../mem/slab_allocator.zig");
const fs = @import("../fs.zig");

// TODO: this is an abysmal solution and i am ashamed of myself. replace this with something nicer

const RegularFile = struct {
    data: []const u8,
};

const Directory = struct {
    child_count: usize,
    children: std.DoublyLinkedList,

    fn findChild(self: *Directory, name: []const u8) ?*File {
        var node = self.children.first;
        while (node) |child_node| : (node = child_node.next) {
            const child: *File = @fieldParentPtr("directory_node", child_node);
            if (std.mem.eql(u8, child.name, name)) return child;
        }

        return null;
    }

    /// The caller must make sure the child does not exist.
    fn addChild(self: *Directory, file_cache: slab_allocator.ObjectCache(File), name: []const u8) !*File {
        const new_file = try file_cache.alloc();
        new_file.name = name;
        self.children.append(&new_file.directory_node);
        self.child_count += 1;

        return new_file;
    }

    fn dumpTree(self: *Directory, depth: usize) void {
        var indentation_buff: [256]u8 = undefined;
        const indentation_size = depth * 4;
        for (0..indentation_size) |i|
            indentation_buff[i] = ' ';

        const indentation = indentation_buff[0..indentation_size];

        var node = self.children.first;
        while (node) |child_node| : (node = child_node.next) {
            const child: *File = @fieldParentPtr("directory_node", child_node);
            std.log.debug("{s}{s}", .{ indentation, child.name });

            switch (child.data) {
                .regular => {},
                .directory => |*dir| {
                    dir.dumpTree(depth + 1);
                },
            }
        }
    }
};

const File = struct {
    name: []const u8,
    data: Data,
    directory_node: std.DoublyLinkedList.Node,

    const DataType = enum {
        regular,
        directory,
    };

    const Data = union(DataType) {
        regular: RegularFile,
        directory: Directory,
    };
};

pub const RamFs = struct {
    root_directory: Directory,
    file_cache: slab_allocator.ObjectCache(File),

    // TODO: GET RID OF THIS UGLY MESS
    pub fn addFile(self: *RamFs, full_path: []const u8, content: []const u8) !void {
        var current_dir: *Directory = &self.root_directory;
        var path_iterator = try PathIterator.fromString(full_path);

        while (path_iterator.next()) |path_segment| {
            const existing_child = current_dir.findChild(path_segment);
            if (path_iterator.reachedEnd()) {
                if (existing_child != null) return error.AlreadyExists;

                var new_file = try current_dir.addChild(self.file_cache, path_segment);
                new_file.data = .{ .regular = .{ .data = content } };
            } else {
                const dir = existing_child orelse
                    blk: {
                        const new_dir = try current_dir.addChild(self.file_cache, path_segment);
                        new_dir.data = .{
                            .directory = .{
                                .child_count = 0,
                                .children = .{},
                            },
                        };
                        break :blk new_dir;
                    };

                current_dir = &dir.data.directory;
            }
        }
    }

    pub fn dumpTree(self: *RamFs) void {
        self.root_directory.dumpTree(0);
    }

    pub fn init(self: *RamFs) fs.FileSystemError!void {
        self.file_cache = slab_allocator.createObjectCache(File);
        self.root_directory = .{
            .child_count = 0,
            .children = .{},
        };
    }
};

pub fn init(internal_data: *anyopaque) fs.FileSystemError!void {
    const ramfs: *RamFs = @ptrCast(@alignCast(internal_data));
    return ramfs.init();
}
