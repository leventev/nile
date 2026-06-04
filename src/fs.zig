const std = @import("std");
const arch = @import("arch/arch.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const Path = @import("Path.zig");

pub const Inode = enum(u64) {
    _,

    pub fn fromInt(val: u64) Inode {
        return @enumFromInt(val);
    }

    pub fn asInt(self: Inode) u64 {
        return @intFromEnum(self);
    }
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

        /// File system has no block device backing it and lives entirely in
        /// the file system cache
        no_device: bool = false,
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
    // TODO: clean name
    /// Path
    path: []const u8,

    // null if root
    file: ?OpenFile,

    /// Mounted file system
    file_system: *MountedFileSystem,

    /// Mount flags
    flags: Flags,

    /// Linked list node pointing to the next mount in a process's mount table.
    next: ?*Mount,

    const Id = enum(u32) { _ };

    /// Mount flags.
    const Flags = packed struct {};

    var cache: slab_allocator.ObjectCache(Mount) = undefined;
};

pub const DeviceId = struct {
    major: u16,
    minor: u16,
};

const FileSystemCache = struct {
    root_directory: Directory,
    ids_available: std.bit_set.ArrayBitSet(usize, DirectoryEntry.Id.max) = .full,

    const DirectoryEntry = struct {
        id: Id,
        name: []const u8,
        data: FileData,
        reference_count: usize,
        next: ?*DirectoryEntry,

        var cache: slab_allocator.ObjectCache(DirectoryEntry) = undefined;

        const Id = enum(usize) {
            _,
            const max = 4096;
        };
    };

    const FileType = enum {
        regular,
        directory,
    };

    const FileData = union(FileType) {
        regular: Regular,
        directory: Directory,
    };

    const Regular = struct {
        // TODO: temporary
        data: []const u8,
    };

    // TODO: ERRORS

    const Directory = struct {
        entry_count: usize,
        entries: ?*DirectoryEntry,

        fn lookup(self: *Directory, name: []const u8) *?*DirectoryEntry {
            var dent_ptr = &self.entries;
            while (dent_ptr.*) |dent| : (dent_ptr = &dent.next) {
                if (std.mem.eql(u8, dent.name, name))
                    break;
            }
            return dent_ptr;
        }

        fn create(self: *Directory, name: []const u8, file_data: FileData) !void {
            const dent_ptr = self.lookup(name);

            if (dent_ptr.* != null) return error.AlreadyExists;

            var new_entry = try DirectoryEntry.cache.alloc();
            new_entry.name = name;
            new_entry.data = file_data;
            new_entry.next = null;

            dent_ptr.* = new_entry;
        }
    };
};

/// A mounted file system. Can be associated with a device whose ID then can uniquely identify
/// a mounted file system. Not providing a device ID could be useful for in-memory file systems
/// e.g. ramfs. If the reference count reaches 0 then the struct is deallocated(TODO).
const MountedFileSystem = struct {
    id: Id,

    /// The device the file system is mounted on. Usually null if the file system is ramfs.
    /// In that case the reference count cannot go above 1.
    device: ?DeviceId,

    /// Mounted file system type
    file_system: *FileSystem,

    /// The internal data of the mounted file system.
    internal_data: *anyopaque,

    /// The total (global) number of times this file system (identified by the device) is mounted.
    reference_count: usize,

    fs_cache: FileSystemCache,

    /// Linked list node pointing to the next mounted file system.
    list_node: std.SinglyLinkedList.Node,

    const Id = enum(usize) { _ };

    var cache: slab_allocator.ObjectCache(MountedFileSystem) = undefined;

    // TODO: TEMPORARY, NOT EVEN LOCKED
    var counter: usize = 0;
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
    mounts: ?*Mount,

    /// Number of mounts in the list
    mount_count: usize,

    /// Lock
    lock: arch.Lock,

    pub fn dump(self: *MountTable) void {
        self.lock.lock();
        defer self.lock.unlock();

        std.log.info("Mounts in namespaces({}):", .{self.mount_count});
        var mount_ptr = self.mounts;
        while (mount_ptr) |mount| : (mount_ptr = mount.next) {
            std.log.info("  {s} - {s}", .{ mount.path, mount.file_system.file_system.name });
        }
    }

    /// If a mount matches the provided path return a pointer to the 'next' pointer pointing to it.
    /// Otherwise returns a pointer to the last element's 'next' pointer (which points to null).
    pub fn findMount(self: *MountTable, path: []const u8) *?*Mount {
        var mount_ptr = &self.mounts;
        while (mount_ptr.*) |mount| : (mount_ptr = &mount.next) {
            if (std.mem.eql(u8, mount.path, path))
                break;
        }

        return mount_ptr;
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
    // TODO: special case mounting root

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

    const mount_next_ptr = mount_table.findMount(path);
    if (mount_next_ptr.* != null) return error.AlreadyMounted;

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

    const source_file: ?OpenFile = if (std.mem.eql(u8, path, "/"))
        null
    else
        try openFile(mount_table, path);

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

    var new_mount = try Mount.cache.alloc();
    errdefer Mount.cache.free(new_mount);

    new_mount.flags = .{};
    // TODO: copy name
    new_mount.path = path;
    new_mount.file = source_file;
    new_mount.next = null;
    mount_next_ptr.* = new_mount;

    if (existing_mounted_fs.*) |mounted_fs_node| {
        var mounted_fs: *MountedFileSystem = @fieldParentPtr("list_node", mounted_fs_node);
        mounted_fs.reference_count += 1;
        mounted_fs.id = @enumFromInt(MountedFileSystem.counter);
        MountedFileSystem.counter += 1;
        new_mount.file_system = mounted_fs;
    } else {
        var new_mounted_fs = try MountedFileSystem.cache.alloc();

        new_mounted_fs.device = null;
        new_mounted_fs.file_system = file_system;
        // TODO: internal data
        new_mounted_fs.reference_count = 1;
        new_mounted_fs.list_node = .{};

        new_mount.file_system = new_mounted_fs;
        existing_mounted_fs.* = &new_mounted_fs.list_node;
    }

    mount_table.mount_count += 1;
}

pub const OpenFile = struct {
    mounted_fs_id: MountedFileSystem.Id,
    file_id: FileSystemCache.DirectoryEntry.Id,
};

pub fn walkUntilLastComponent(
    mount_table: *MountTable,
    path_str: []const u8,
    out_mnt: **Mount,
    out_parent_dir: **FileSystemCache.Directory,
    out_last_component: *[]const u8,
) !void {
    // TODO: LOCKING

    // TODO: clean name (VERY IMPORTANT!!!!)

    if (path_str.len == 0 or path_str[0] != '/') return error.InvalidPath;

    // TODO: consider saving the root mapping in MountTable for easier access
    const root_mount = mount_table.mounts orelse @panic("No root mount");

    var current_mount = root_mount;
    var current_fs = root_mount.file_system;
    var current_dir = &current_fs.fs_cache.root_directory;

    var path = try Path.fromStringWithSlash(path_str);
    while (path.next()) |path_element| {
        const traversed_path = path.alreadyTraversed();
        const is_last_component = path.reachedEnd();
        std.log.debug("traversed: {s}, is_last: {}", .{ traversed_path, is_last_component });

        if (mount_table.findMount(traversed_path).*) |mount| {
            std.log.debug("found mount: {s}", .{mount.path});
            current_mount = mount;
            current_fs = current_mount.file_system;
            current_dir = &current_fs.fs_cache.root_directory;
            continue;
        }

        const dir_entry_ptr = current_dir.lookup(path_element);
        std.log.debug("dir ent: {}", .{dir_entry_ptr});
        if (is_last_component) {
            out_mnt.* = current_mount;
            out_last_component.* = path_element;
            out_parent_dir.* = current_dir;
        } else {
            if (dir_entry_ptr.*) |dir_entry| {
                std.log.debug("dir entry", .{});
                switch (dir_entry.data) {
                    .regular => return error.EntryNotFound,
                    .directory => |*dir| current_dir = dir,
                }
            } else {
                if (current_fs.file_system.flags.no_device) {
                    return error.EntryNotFound;
                } else {
                    @panic("TODO");
                }
            }
        }
    }
}

pub fn createDirectory(mount_table: *MountTable, path_str: []const u8) !void {
    var mount: *Mount = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(mount_table, path_str, &mount, &dir, &last_component);

    try dir.create(last_component, .{ .directory = .{ .entry_count = 0, .entries = null } });
}

// TODO: CONTENT
pub fn createRegularFile(mount_table: *MountTable, path_str: []const u8, content: []const u8) !void {
    var mount: *Mount = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(mount_table, path_str, &mount, &dir, &last_component);

    try dir.create(last_component, .{ .regular = .{ .data = content } });
}

// TODO: ERRORS
pub fn openFile(mount_table: *MountTable, path_str: []const u8) !OpenFile {
    var mount: *Mount = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(mount_table, path_str, &mount, &dir, &last_component);

    const dir_entry = dir.lookup(last_component).* orelse return error.EntryNotFound;
    // TODO: LOCKING

    dir_entry.reference_count += 1;
    return OpenFile{
        // TODO
        .mounted_fs_id = @enumFromInt(0),
        .file_id = dir_entry.id,
    };
}

pub fn dumpTree(mount_table: *MountTable) void {
    // TODO: this only prints the root mount
    const root_mount = mount_table.mounts orelse @panic("No root mount");
    const root_fs = root_mount.file_system;
    const root_dir = &root_fs.fs_cache.root_directory;
    dumpDirectory(root_dir, 0);
}

fn dumpDirectory(dir: *FileSystemCache.Directory, depth: usize) void {
    // TODO: buffer likely too small
    const space_count = depth * 4;
    var indent_buffer: [512]u8 = undefined;
    for (0..space_count) |i| indent_buffer[i] = ' ';

    var dir_ent_ptr = dir.entries;
    while (dir_ent_ptr) |dir_ent| : (dir_ent_ptr = dir_ent.next) {
        switch (dir_ent.data) {
            .regular => |child_file| std.log.info("{s}{s} [{} bytes]", .{
                indent_buffer[0..space_count],
                dir_ent.name,
                child_file.data.len,
            }),
            .directory => |*child_dir| {
                std.log.info("{s}{s}:", .{ indent_buffer[0..space_count], dir_ent.name });
                dumpDirectory(child_dir, depth + 1);
            },
        }
    }
}

/// Initialize the Virtual File System.
pub fn init() void {
    Mount.cache = slab_allocator.createObjectCache(Mount);
    MountedFileSystem.cache = slab_allocator.createObjectCache(MountedFileSystem);
    FileSystemCache.DirectoryEntry.cache = slab_allocator.createObjectCache(FileSystemCache.DirectoryEntry);
}
