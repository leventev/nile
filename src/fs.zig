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

pub const FileSystemError = std.mem.Allocator.Error || error{};

/// A file system skeleton/descritpor contains its name, flags and operations.
///
/// Before calling registerFileSystem all fields must be initialized appropriately
/// except list_node which will be set by the VFS.
pub const FileSystemSkeleton = struct {
    /// Name of the file system
    name: []const u8,

    /// Called when the file system is created
    init: *const fn (gpa: std.mem.Allocator) FileSystemError!?*anyopaque,

    /// File system flags
    flags: Flags,

    /// Set by the VFS
    next: ?*FileSystemSkeleton = null,

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
var file_system_skeletons: struct {
    /// Linked list of the file system skeletons
    head: ?*FileSystemSkeleton = null,

    /// The number of registed file system skeletons
    count: usize = 0,

    /// Lock
    lock: arch.Lock = .{},

    /// If an fs matches the provided name return a pointer to the 'next' pointer pointing to it.
    /// Otherwise returns a pointer to the last element's 'next' pointer (which points to null).
    /// While performing operations on the list the lock shall be locked.
    fn getByName(self: *@This(), name: []const u8) *?*FileSystemSkeleton {
        var fs_next_ptr = &self.head;
        while (fs_next_ptr.*) |fs| : (fs_next_ptr = &fs.next)
            if (std.mem.eql(u8, fs.name, name))
                break;

        return fs_next_ptr;
    }
} = .{};

/// Register a file system.
/// The recommended way to store FileSystem is to make it a global variable and store
/// it in the data section, that way we don't need to worry about its lifetime.
pub fn registerFileSystem(file_system: *FileSystemSkeleton) void {
    file_system_skeletons.lock.lock();
    defer file_system_skeletons.lock.unlock();

    const fs_next_ptr = file_system_skeletons.getByName(file_system.name);
    std.debug.assert(fs_next_ptr.* == null);

    fs_next_ptr.* = file_system;
    file_system.next = null;
    file_system_skeletons.count += 1;
}

/// Unregister a file system.
/// TODO: check if fs is mounted
pub fn unregisterFileSystem(name: []const u8) void {
    file_system_skeletons.lock.lock();
    defer file_system_skeletons.lock.unlock();

    const fs_next_ptr = file_system_skeletons.getByName(name);
    const fs = fs_next_ptr.*.?;

    fs_next_ptr.* = fs.next;
    fs.next = null;
    file_system_skeletons.count -= 1;
}

/// Print registered file systems
pub fn dumpRegisteredFilesystems() void {
    file_system_skeletons.lock.lock();
    defer file_system_skeletons.lock.unlock();

    std.log.debug("Registered file systems({}):", .{file_system_skeletons.count});
    var fs_ptr = file_system_skeletons.head;
    while (fs_ptr) |fs| : (fs_ptr = fs.next) {
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
    file_system: *FileSystem,

    /// Mount flags
    flags: Flags,

    /// Linked list node pointing to the next mount in a process's mount table.
    next: ?*Mount,

    const Id = enum(u32) { _ };

    /// Mount flags.
    const Flags = packed struct {};

    var cache: slab_allocator.ObjectCache(Mount) = undefined;
};

pub const FileSystemDeviceId = struct {
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

/// An existing file system. There can be multiple existing file systems with the same skeleton.
/// It can be associated with a device whose ID then can uniquely identify the file system.
/// Not providing a device ID could be useful for in-memory file systems e.g. ramfs, devfs.
/// If the reference count reaches 0 then the struct is deallocated(TODO: make it a flag).
const FileSystem = struct {
    id: Id,

    /// The device the file system resides on.
    device: ?FileSystemDeviceId,

    /// File system skeleton.
    skeleton: *FileSystemSkeleton,

    /// The internal data of the file system.
    internal_data: ?*anyopaque,

    /// The total (global) number of times this file system (identified by the device) is mounted.
    mount_count: usize,

    fs_cache: FileSystemCache,

    /// Linked list node pointing to the next mounted file system.
    next: ?*FileSystem,

    const Id = enum(usize) { _ };

    var cache: slab_allocator.ObjectCache(FileSystem) = undefined;

    // TODO: TEMPORARY, NOT EVEN LOCKED
    var counter: usize = 0;
};

var global_file_system_table: struct {
    mounted_file_systems: ?*FileSystem = null,
    // TODO: no global lock?
    lock: arch.Lock = .{},

    /// If an fs matches the provided id return a pointer to the 'next' pointer pointing to it.
    /// Otherwise returns a pointer to the last element's 'next' pointer (which points to null).
    fn getById(self: *@This(), id: FileSystem.Id) *?*FileSystem {
        var fs_next_ptr = &self.mounted_file_systems;
        while (fs_next_ptr.*) |fs| : (fs_next_ptr = &fs.next) {
            if (fs.id == id) break;
        }

        return fs_next_ptr;
    }

    fn getByDeviceId(self: *@This(), device_id: FileSystemDeviceId) *?*FileSystem {
        var fs_next_ptr = &self.mounted_file_systems;
        while (fs_next_ptr.*) |fs| : (fs_next_ptr = &fs.next) {
            const device_id_fs = fs.device orelse continue;

            if (device_id.major == device_id_fs.major and device_id.minor == device_id.minor)
                break;
        }

        return fs_next_ptr;
    }
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
            std.log.info("  {s} - {s}", .{ mount.path, mount.file_system.skeleton.name });
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
pub fn createFileSystem(gpa: std.mem.Allocator, fs_name: []const u8) !*FileSystem {
    file_system_skeletons.lock.lock();
    defer file_system_skeletons.lock.unlock();

    const skel = file_system_skeletons.getByName(fs_name).* orelse return error.FsNotRegistered;

    const internal_data = try skel.init(gpa);
    // TODO: errdefer cleanup

    var fs = try FileSystem.cache.alloc();
    fs.skeleton = skel;
    fs.device = null;
    fs.mount_count = 0;
    fs.next = null;
    fs.internal_data = internal_data;
    fs.id = @enumFromInt(FileSystem.counter);
    FileSystem.counter += 1;

    var next_ptr = &global_file_system_table.mounted_file_systems;
    while (next_ptr.*) |ptr| : (next_ptr = &ptr.next) {}

    next_ptr.* = fs;

    return fs;
}

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
    fs: *FileSystem,
) !void {
    // TODO: special case mounting root

    // TODO: the order shouldnt matter here, right?
    mount_table.lock.lock();
    file_system_skeletons.lock.lock();
    global_file_system_table.lock.lock();
    defer {
        mount_table.lock.unlock();
        file_system_skeletons.lock.unlock();
        global_file_system_table.lock.unlock();
    }

    // TODO: validate path
    // TODO: we may want to abstract the linked list searches

    const mount_next_ptr = mount_table.findMount(path);
    if (mount_next_ptr.* != null) return error.AlreadyMounted;

    const source_file: ?OpenFile = if (std.mem.eql(u8, path, "/"))
        null
    else
        try openFile(mount_table, path);

    var new_mount = try Mount.cache.alloc();
    errdefer Mount.cache.free(new_mount);

    mount_table.mount_count += 1;
    mount_next_ptr.* = new_mount;

    new_mount.flags = .{};
    // TODO: copy name
    new_mount.path = path;
    new_mount.file = source_file;
    new_mount.next = null;
    new_mount.file_system = fs;

    fs.mount_count += 1;
}

pub const OpenFile = struct {
    mounted_fs_id: FileSystem.Id,
    dir_ent: *FileSystemCache.DirectoryEntry,

    pub fn read(self: OpenFile, buff: []u8, offset: usize) usize {
        const fs = global_file_system_table.getById(self.mounted_fs_id).* orelse
            @panic("Invalid open file");
        _ = fs;

        switch (self.dir_ent.data) {
            .directory => @panic("TODO: directory read"),
            .regular => |regular| {
                // TODO:
                const data = regular.data;
                if (data.len <= offset) return 0;
                const rem_size = data.len - offset;

                const read_len = @min(rem_size, buff.len);
                @memcpy(buff[0..read_len], data[offset .. offset + read_len]);

                return read_len;
            },
        }
        return;
    }

    pub fn write(self: OpenFile, buff: []u8, offset: usize) usize {
        _ = buff;
        _ = offset;
        const fs = global_file_system_table.getById(self.mounted_fs_id).* orelse
            @panic("Invalid open file");
        _ = fs;

        switch (self.dir_ent.data) {
            .directory => @panic("TODO: directory write"),
            .regular => @panic("TODO: regular write"),
        }
        return;
    }
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

        if (mount_table.findMount(traversed_path).*) |mount| {
            current_mount = mount;
            current_fs = current_mount.file_system;
            current_dir = &current_fs.fs_cache.root_directory;
            continue;
        }

        const dir_entry_ptr = current_dir.lookup(path_element);
        if (is_last_component) {
            out_mnt.* = current_mount;
            out_last_component.* = path_element;
            out_parent_dir.* = current_dir;
        } else {
            if (dir_entry_ptr.*) |dir_entry| {
                switch (dir_entry.data) {
                    .regular => return error.EntryNotFound,
                    .directory => |*dir| current_dir = dir,
                }
            } else {
                if (current_fs.skeleton.flags.no_device) {
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
        .dir_ent = dir_entry,
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
    FileSystem.cache = slab_allocator.createObjectCache(FileSystem);
    FileSystemCache.DirectoryEntry.cache = slab_allocator.createObjectCache(FileSystemCache.DirectoryEntry);
}
