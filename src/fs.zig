const std = @import("std");
const arch = @import("arch/arch.zig");
const slab_allocator = @import("mem/slab_allocator.zig");

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
    registered_file_systems.lock.lock();
    defer registered_file_systems.lock.unlock();

    std.log.debug("Registered file systems({}):", .{registered_file_systems.count});
    var node = registered_file_systems.list.first;
    while (node) |list_node| : (node = list_node.next) {
        const fs: *FileSystem = @fieldParentPtr("list_node", list_node);
        std.log.debug("  {s}", .{fs.name});
    }
}

/// An entry in a per-process MountTable. The path can be used to identify the entry.
const Mount = struct {
    /// Path the file system is mounted on
    /// TODO: struct Path?
    path: []const u8,

    /// Mounted file system type
    file_system: *FileSystem,

    /// Mount flags
    flags: Flags,

    /// Linked list node pointing to the next mount in a process's mount table.
    namespace_list_node: std.SinglyLinkedList.Node,

    /// Mount flags.
    const Flags = packed struct {};

    var cache: slab_allocator.ObjectCache(Mount) = undefined;
};

pub const DeviceId = struct {
    major: u16,
    minor: u16,
};

/// A mounted file system. Can be associated with a device whose ID then can uniquely identify
/// a mounted file system. Not providing a device ID could be useful for in-memory file systems
/// e.g. ramfs. If the reference count reaches 0 then the struct is deallocated(TODO).
const MountedFileSystem = struct {
    /// The device the file system is mounted on. Usually null if the file system is ramfs.
    /// In that case the reference count cannot go above 1.
    device: ?DeviceId,

    /// Mounted file system type
    file_system: *FileSystem,

    /// The internal data of the mounted file system.
    internal_data: *anyopaque,

    /// The total (global) number of times this file system (identified by the device) is mounted.
    reference_count: usize,

    /// Linked list node pointing to the next mounted file system.
    list_node: std.SinglyLinkedList.Node,

    var cache: slab_allocator.ObjectCache(MountedFileSystem) = undefined;
};

var global_file_system_table: struct {
    mounted_file_systems: std.SinglyLinkedList = .{},
    // TODO: no global lock?
    lock: arch.Lock = .{},
} = .{};

/// Per process mount table. Contains a singly linked list of struct Mount.
/// New entries are appended to the end.
pub const MountTable = struct {
    /// Linked list of struct Mount
    mounts: std.SinglyLinkedList,

    /// Number of mounts in the list
    mount_count: usize,

    /// Lock
    lock: arch.Lock,

    pub fn dump(self: *MountTable) void {
        self.lock.lock();
        defer self.lock.unlock();

        std.log.debug("Mounts in namespaces({}):", .{self.mount_count});
        var node = self.mounts.first;
        while (node) |list_node| : (node = list_node.next) {
            const mount: *Mount = @fieldParentPtr("namespace_list_node", list_node);
            std.log.debug("  {s} - {s}", .{ mount.path, mount.file_system.name });
        }
    }
};

// TODO: explicit errors

/// Attach a file system to the specified path.
/// Trying to mount to an existing path or trying to mount an unregistered file system
/// results in an error.
/// If an already mounted (globally, not just in the namespace) file system (MountedFileSystem) uses
/// the same device its reference count is incremented. Otherwise a new MountedFileSystem is
/// created.
/// If no device is specified then the reference count cannot go above 1 since there is no way
/// to distinguish it from others.
/// Appends the new mount to the end of the mount table.
pub fn mountFileSystem(
    mount_table: *MountTable,
    path: []const u8,
    fs_name: []const u8,
    dev_id: ?DeviceId,
) !void {
    // TODO: the order shouldnt matter here, right?
    mount_table.lock.lock();
    registered_file_systems.lock.lock();
    global_file_system_table.lock.lock();
    defer {
        mount_table.lock.unlock();
        registered_file_systems.lock.unlock();
        global_file_system_table.lock.unlock();
    }

    // TODO: validate path
    // TODO: we may want to abstract the linked list searches

    var mnt_node_ptr = &mount_table.mounts.first;
    while (mnt_node_ptr.*) |mnt_node| : (mnt_node_ptr = &mnt_node.next) {
        const mount: *Mount = @fieldParentPtr("namespace_list_node", mnt_node);
        if (std.mem.eql(u8, mount.path, path))
            return error.AlreadyMounted;
    }

    const file_system = blk: {
        var fs_node_ptr: *?*std.SinglyLinkedList.Node = &registered_file_systems.list.first;
        while (fs_node_ptr.*) |list_node| : (fs_node_ptr = &list_node.next) {
            const fs: *FileSystem = @fieldParentPtr("list_node", list_node);
            if (std.mem.eql(u8, fs.name, fs_name)) {
                break :blk fs;
            }
        }
        return error.FsNotRegistered;
    };

    // either points to the 'next' pointer that points to the MountedFileSystem that matches
    // the device id or points to the last element's 'next' pointer (which contains null)
    const existing_mounted_fs: *?*std.SinglyLinkedList.Node = blk: {
        var fs_node_ptr = &global_file_system_table.mounted_file_systems.first;
        while (fs_node_ptr.*) |list_node| : (fs_node_ptr = &list_node.next) {
            const device_id = dev_id orelse continue;

            const fs: *MountedFileSystem = @fieldParentPtr("list_node", list_node);
            const device_id_fs = fs.device orelse continue;

            if (device_id.major == device_id_fs.major and device_id.minor == device_id.minor)
                break :blk fs_node_ptr;
        }
        break :blk fs_node_ptr;
    };

    if (existing_mounted_fs.*) |mounted_fs_node| {
        var mounted_fs: *MountedFileSystem = @fieldParentPtr("list_node", mounted_fs_node);
        mounted_fs.reference_count += 1;
    } else {
        var new_mounted_fs = try MountedFileSystem.cache.alloc();
        // TODO: free new_mounted_fs if mount allocation failed

        new_mounted_fs.device = null;
        new_mounted_fs.file_system = file_system;
        // TODO: internal data
        new_mounted_fs.reference_count = 1;
        new_mounted_fs.list_node = .{};

        existing_mounted_fs.* = &new_mounted_fs.list_node;
    }

    var new_mount = try Mount.cache.alloc();
    new_mount.file_system = file_system;
    new_mount.flags = .{};
    // TODO: copy name
    new_mount.path = path;
    new_mount.namespace_list_node = .{};
    mnt_node_ptr.* = &new_mount.namespace_list_node;

    mount_table.mount_count += 1;
}

/// Initialize the Virtual File System.
pub fn init() void {
    Mount.cache = slab_allocator.createObjectCache(Mount);
    MountedFileSystem.cache = slab_allocator.createObjectCache(MountedFileSystem);
}
