const std = @import("std");
const arch = @import("arch/arch.zig");

pub const Inode = enum(u64) {
    _,

    pub fn fromInt(val: u64) Inode {
        return @enumFromInt(val);
    }

    pub fn asInt(self: Inode) u64 {
        return @intFromEnum(self);
    }
};

const DirectoryEntry = struct {
    inode: Inode,
};

pub const FileSystemError = error{};

/// A file system descriptor contains its name, flags and operations.
///
/// Before calling registerFileSystem all fields must be initialized appropriately
/// except list_node which will be set by the VFS.
pub const FileSystem = struct {
    /// Name of the file system
    name: []const u8,

    /// Called when the file system is mounted
    mount_init: *const fn (internal_data: *anyopaque) FileSystemError!void,

    /// File system flags
    flags: Flags,

    /// Set by the VFS
    list_node: std.SinglyLinkedList.Node = undefined,

    /// File system flags
    pub const Flags = packed struct {
        /// Can only be mounted as a read-only file system
        read_only_mount: bool = false,
    };
};

/// File systems registered in the VFS
var registered_file_systems: struct {
    /// Linked list of the file systems
    list: std.SinglyLinkedList = .{},

    /// The number of registed file systems
    count: usize = 0,

    /// Lock
    lock: arch.Lock = .{},
} = .{};

/// Register a file system.
/// The recommended way to store FileSystem is to make it a global variable and store
/// it in the data section, that way we don't need to worry about its lifetime.
pub fn registerFileSystem(file_system: *FileSystem) error{FsAlreadyRegistered}!void {
    registered_file_systems.lock.lock();
    defer registered_file_systems.lock.unlock();

    var node_ptr: *?*std.SinglyLinkedList.Node = &registered_file_systems.list.first;

    while (node_ptr.*) |list_node| : (node_ptr = &list_node.next) {
        const fs: *FileSystem = @fieldParentPtr("list_node", list_node);
        if (std.mem.eql(u8, fs.name, file_system.name)) {
            return error.FsAlreadyRegistered;
        }
    }

    node_ptr.* = &file_system.list_node;
    file_system.list_node.next = null;
    registered_file_systems.count += 1;
}

/// Unregister a file system.
/// TODO: check if fs is mounted
pub fn unregisterFileSystem(name: []const u8) error{FsNotRegistered}!void {
    registered_file_systems.lock.lock();
    defer registered_file_systems.lock.unlock();

    var node_ptr: *?*std.SinglyLinkedList.Node = &registered_file_systems.list.first;
    while (node_ptr.*) |list_node| : (node_ptr = &list_node.next) {
        const fs: *FileSystem = @fieldParentPtr("list_node", list_node);
        if (std.mem.eql(u8, fs.name, name)) {
            node_ptr.* = list_node.next;
            registered_file_systems.count -= 1;
            return;
        }
    }

    return error.FsNotRegistered;
}

/// Print registered file systems
pub fn dumpRegisteredFilesystems() void {
    std.log.debug("Registered file systems({}):", .{registered_file_systems.count});
    var node = registered_file_systems.list.first;
    while (node) |list_node| : (node = list_node.next) {
        const fs: *FileSystem = @fieldParentPtr("list_node", list_node);
        std.log.debug("  {s}", .{fs.name});
    }
}

pub fn init() void {}
