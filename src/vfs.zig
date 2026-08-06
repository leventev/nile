const std = @import("std");
const arch = @import("arch/arch.zig");
const slab_allocator = @import("mem/slab_allocator.zig");
const Path = @import("Path.zig");
const PageCache = @import("PageCache.zig");
const core = @import("core");
const SyscallError = core.SyscallError;
const sync = @import("sync.zig");

pub const Inode = enum(u32) {
    _,

    pub fn fromInt(val: u32) Inode {
        return @enumFromInt(val);
    }

    pub fn asInt(self: Inode) u32 {
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
    init: *const fn (gpa: std.mem.Allocator, fs: *FileSystem) FileSystemError!?*anyopaque,

    operations: ?Operations,

    /// File system flags
    flags: Flags,

    /// Set by the VFS
    next: ?*FileSystemSkeleton = null,

    pub fn isSpecial(self: *FileSystemSkeleton) bool {
        return self.operations == null and !self.flags.has_page_cache;
    }

    /// File system flags
    pub const Flags = packed struct {
        /// Can only be mounted as a read-only file system
        read_only_mount: bool = false,

        /// File system has no block device backing it and lives entirely in
        /// the file system cache.
        no_device: bool = false,

        /// Whether the device uses the page cache or not.
        has_page_cache: bool = true,
    };

    pub const Operations = struct {
        read: *const fn (
            internal_data: ?*anyopaque,
            inode: Inode,
            buff: []u8,
            offset: usize,
        ) FileSystemError!usize = &readStub,

        write: *const fn (
            internal_data: ?*anyopaque,
            inode: Inode,
            buff: []const u8,
            offset: usize,
        ) FileSystemError!usize = &writeStub,

        pub fn readStub(_: ?*anyopaque, _: Inode, _: []const u8, _: usize) FileSystemError!usize {
            return 0;
        }

        pub fn writeStub(_: ?*anyopaque, _: Inode, _: []const u8, _: usize) FileSystemError!usize {
            return 0;
        }
    };
};

/// File systems registered in the VFS
var file_system_skeletons: struct {
    /// Linked list of the file system skeletons
    head: ?*FileSystemSkeleton = null,

    /// The number of registed file system skeletons
    count: usize = 0,

    /// Lock
    spinlock: sync.Spinlock = .{},

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
    file_system_skeletons.spinlock.lock();
    defer file_system_skeletons.spinlock.unlock();

    const fs_next_ptr = file_system_skeletons.getByName(file_system.name);
    std.debug.assert(fs_next_ptr.* == null);

    fs_next_ptr.* = file_system;
    file_system.next = null;
    file_system_skeletons.count += 1;
}

/// Unregister a file system.
/// TODO: check if fs is mounted
pub fn unregisterFileSystem(name: []const u8) void {
    file_system_skeletons.spinlock.lock();
    defer file_system_skeletons.spinlock.unlock();

    const fs_next_ptr = file_system_skeletons.getByName(name);
    const fs = fs_next_ptr.*.?;

    fs_next_ptr.* = fs.next;
    fs.next = null;
    file_system_skeletons.count -= 1;
}

/// Print registered file systems
pub fn dumpRegisteredFilesystems() void {
    file_system_skeletons.spinlock.lock();
    defer file_system_skeletons.spinlock.unlock();

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

pub const FileSystemCache = struct {
    root_directory: Directory,
    ids_available: std.bit_set.ArrayBitSet(usize, DirectoryEntry.Id.max) = .full,

    /// A generic directory entry in the fs cache. It is embedded in the Regular, RegularUnique
    /// and Directory structures to save memory and to try to keep the structs in the
    /// same cache line.
    pub const DirectoryEntry = struct {
        inode: Inode,
        name: []const u8,
        filetype: FileType,
        reference_count: usize,
        next: ?*DirectoryEntry,

        pub const Id = enum(usize) {
            _,
            const max = 4096;
        };

        // TODO: do checks for all these
        pub fn regular(self: *DirectoryEntry) *Regular {
            return @fieldParentPtr("common", self);
        }

        pub fn regularUnique(self: *DirectoryEntry) *RegularUnique {
            return @fieldParentPtr("common", self);
        }

        pub fn directory(self: *DirectoryEntry) *Directory {
            return @fieldParentPtr("common", self);
        }
    };

    pub const FileType = enum {
        regular,
        directory,
    };

    pub const Regular = struct {
        common: DirectoryEntry,
        size: usize,
        page_cache: PageCache,

        var cache: slab_allocator.ObjectCache(Regular) = undefined;
    };

    pub const RegularUnique = struct {
        common: DirectoryEntry,
        internal_data: ?*anyopaque,
        operations: FileSystemSkeleton.Operations,

        var cache: slab_allocator.ObjectCache(RegularUnique) = undefined;
    };

    pub const Directory = struct {
        common: DirectoryEntry,
        entry_count: usize,
        entries: ?*DirectoryEntry,

        var cache: slab_allocator.ObjectCache(Directory) = undefined;

        pub fn lookup(self: *Directory, name: []const u8) *?*DirectoryEntry {
            var dent_ptr = &self.entries;
            while (dent_ptr.*) |dent| : (dent_ptr = &dent.next)
                if (std.mem.eql(u8, dent.name, name))
                    break;

            return dent_ptr;
        }

        pub fn createDirectory(self: *Directory, name: []const u8, inode: Inode) !void {
            const dent_ptr = self.lookup(name);
            if (dent_ptr.* != null) return error.AlreadyExists;

            var dir = try Directory.cache.alloc();
            dir.* = .{
                .entry_count = 0,
                .entries = null,
                .common = .{
                    .name = name,
                    .filetype = .directory,
                    .inode = inode,
                    .reference_count = 1,
                    .next = null,
                },
            };

            dent_ptr.* = &dir.common;
            self.entry_count += 1;
        }

        pub fn createRegular(self: *Directory, name: []const u8, inode: Inode) !void {
            const dent_ptr = self.lookup(name);
            if (dent_ptr.* != null) return error.AlreadyExists;

            // TODO: size
            var regular = try Regular.cache.alloc();
            errdefer Regular.cache.free(regular);
            regular.* = .{
                .size = 0,
                .page_cache = undefined,
                .common = .{
                    .name = name,
                    .filetype = .regular,
                    .inode = inode,
                    .reference_count = 1,
                    .next = null,
                },
            };
            try regular.page_cache.setup();

            dent_ptr.* = &regular.common;
            self.entry_count += 1;
        }

        pub fn createRegularUnique(
            self: *Directory,
            name: []const u8,
            inode: Inode,
            internal_data: ?*anyopaque,
            operations: *const FileSystemSkeleton.Operations,
        ) !void {
            const dent_ptr = self.lookup(name);
            if (dent_ptr.* != null) return error.AlreadyExists;

            // TODO: size
            var regular = try RegularUnique.cache.alloc();
            regular.* = .{
                .internal_data = internal_data,
                .operations = operations.*,
                .common = .{
                    .name = name,
                    .filetype = .regular,
                    .inode = inode,
                    .reference_count = 1,
                    .next = null,
                },
            };

            dent_ptr.* = &regular.common;
            self.entry_count += 1;
        }
    };
};

/// An existing file system. There can be multiple existing file systems with the same skeleton.
/// It can be associated with a device whose ID then can uniquely identify the file system.
/// Not providing a device ID could be useful for in-memory file systems e.g. ramfs, devfs.
/// If the reference count reaches 0 then the struct is deallocated(TODO: make it a flag).
pub const FileSystem = struct {
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

    pub const Id = enum(usize) { _ };

    var cache: slab_allocator.ObjectCache(FileSystem) = undefined;

    // TODO: TEMPORARY, NOT EVEN LOCKED
    var counter: usize = 0;
};

var global_file_system_table: struct {
    mounted_file_systems: ?*FileSystem = null,
    // TODO: no global lock?
    spinlock: sync.Spinlock = .{},

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
    spinlock: sync.Spinlock,

    pub fn dump(self: *MountTable) void {
        self.spinlock.lock();
        defer self.spinlock.unlock();

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
    file_system_skeletons.spinlock.lock();
    defer file_system_skeletons.spinlock.unlock();

    const skel = file_system_skeletons.getByName(fs_name).* orelse return error.FsNotRegistered;

    // TODO: errdefer cleanup

    var fs = try FileSystem.cache.alloc();
    const internal_data = try skel.init(gpa, fs);

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
    mount_table.spinlock.lock();
    file_system_skeletons.spinlock.lock();
    global_file_system_table.spinlock.lock();
    defer {
        mount_table.spinlock.unlock();
        file_system_skeletons.spinlock.unlock();
        global_file_system_table.spinlock.unlock();
    }

    // TODO: validate path
    // TODO: we may want to abstract the linked list searches

    const mount_next_ptr = mount_table.findMount(path);
    if (mount_next_ptr.* != null) return error.AlreadyMounted;

    const source_file: ?OpenFile = if (std.mem.eql(u8, path, "/"))
        null
    else
        try openFile(mount_table, null, path);

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

pub fn genericReadRegular(
    fs: *FileSystem,
    regular: *FileSystemCache.Regular,
    buff: []u8,
    offset: usize,
) !usize {
    _ = fs;

    std.debug.assert(offset <= regular.size);

    // TODO: support no_device == false too

    const total_read_size = @min(buff.len, regular.size - offset);
    if (total_read_size == 0) return 0;

    const last_byte_idx = offset + total_read_size - 1;

    const start_page_idx = offset / arch.page_size;
    const end_page_idx = last_byte_idx / arch.page_size;

    var buff_off: usize = 0;
    var page_idx = start_page_idx;
    while (page_idx <= end_page_idx) : (page_idx += 1) {
        const page_ptr = regular.page_cache.getPage(page_idx, false) catch unreachable;
        const file_content_ptr = page_ptr.asPtr([*]const u8);
        const file_content: []const u8 = file_content_ptr[0..arch.page_size];

        const buff_remaining = buff.len - buff_off;
        const read_size = @min(buff_remaining, file_content.len);
        @memcpy(buff[buff_off .. buff_off + read_size], file_content[0..read_size]);
        buff_off += read_size;
    }

    return total_read_size;
}

pub fn genericWriteRegular(
    fs: *FileSystem,
    regular: *FileSystemCache.Regular,
    buff: []const u8,
    offset: usize,
) !usize {
    _ = fs;

    // std.log.debug("write {} {} {}", .{ buff.len, regular.size, offset });
    std.debug.assert(offset <= regular.size);

    // TODO: support no_device == false too

    regular.page_cache.spinlock.lock();
    defer regular.page_cache.spinlock.unlock();

    const last_byte_idx = offset + buff.len - 1;

    const start_page_idx = offset / arch.page_size;
    const end_page_idx = last_byte_idx / arch.page_size;

    while (end_page_idx >= regular.page_cache.totalPageCount()) {
        try regular.page_cache.expand();
    }

    var buff_off: usize = 0;
    var page_idx = start_page_idx;
    while (page_idx <= end_page_idx) : (page_idx += 1) {
        const page_ptr = try regular.page_cache.getPage(page_idx, true);
        const file_content_ptr = page_ptr.asPtr([*]u8);
        const file_content: []u8 = file_content_ptr[0..arch.page_size];

        const buff_remaining = buff.len - buff_off;
        const write_size = @min(buff_remaining, file_content.len);
        @memcpy(file_content[0..write_size], buff[buff_off .. buff_off + write_size]);
        buff_off += write_size;
    }

    regular.size = @max(regular.size, offset + buff.len);

    return buff.len;
}

pub const OpenFile = struct {
    mounted_fs_id: FileSystem.Id,
    dir_ent: *FileSystemCache.DirectoryEntry,

    pub fn read(self: OpenFile, buff: []u8, offset: *usize) !usize {
        const fs = global_file_system_table.getById(self.mounted_fs_id).* orelse
            @panic("Invalid open file");

        switch (self.dir_ent.filetype) {
            .directory => {
                const dir = self.dir_ent.directory();
                if (@intFromPtr(buff.ptr) % @alignOf(core.fs.DirectoryEntryHeader) != 0)
                    return error.InvalidMemoryAddress;

                if (offset.* >= dir.entry_count) return 0;

                // TODO: use a tree or smth to store inodes
                var dir_ent_ptr = dir.entries;
                for (0..offset.*) |_|
                    dir_ent_ptr = (dir_ent_ptr orelse @panic("Invalid offset")).next;

                const header_size = @sizeOf(core.fs.DirectoryEntryHeader);

                var total_written_size: usize = 0;
                while (dir_ent_ptr) |dir_ent| : (dir_ent_ptr = dir_ent.next) {
                    const remaining_buff_size = buff.len - total_written_size;
                    const required_size = header_size + dir_ent.name.len;
                    const padded_size = std.mem.alignForward(usize, required_size, header_size);
                    if (required_size > remaining_buff_size)
                        break;

                    const struct_start_ptr = buff.ptr + total_written_size;
                    const name_start_ptr = struct_start_ptr + header_size;
                    const header: *core.fs.DirectoryEntryHeader = @ptrCast(
                        @alignCast(struct_start_ptr),
                    );
                    const name_ptr = name_start_ptr[0..dir_ent.name.len];

                    header.inode = dir_ent.inode.asInt();
                    header.name_size = @intCast(dir_ent.name.len);
                    header.file_type = 0;
                    @memcpy(name_ptr, dir_ent.name);

                    total_written_size += @min(padded_size, remaining_buff_size);
                    offset.* += 1;
                }

                return total_written_size;
            },
            .regular => {
                const read_size = if (fs.skeleton.operations) |ops|
                    // if the fs skeleton has a read function defined we use that to read the
                    // contents of the file, and whether the page cache is enabled for the fs we
                    // use it as a middleman (regular filesystems like ext{2,3,4} would use this)
                    if (fs.skeleton.flags.has_page_cache)
                        try genericReadRegular(fs, self.dir_ent.regular(), buff, offset.*)
                    else
                        try ops.read(fs.internal_data, self.dir_ent.inode, buff, offset.*)
                else if (fs.skeleton.flags.has_page_cache)
                    // otherwise if the page cache is enabled we use it for storing the file
                    // contents without writeback to a block device (ramfs would use this)
                    try genericReadRegular(fs, self.dir_ent.regular(), buff, offset.*)
                else blk: {
                    // otherwise the entry (all entries in this fs) must be a RegularUnique meaning
                    // all of them have different fs operations (devfs, procfs would use this)
                    const regular_unique = self.dir_ent.regularUnique();
                    break :blk regular_unique.operations.read(
                        regular_unique.internal_data,
                        self.dir_ent.inode,
                        buff,
                        offset.*,
                    );
                };

                return read_size;
            },
        }
    }

    pub fn write(self: OpenFile, buff: []const u8, offset: usize) !usize {
        if (buff.len == 0) return 0;

        const fs = global_file_system_table.getById(self.mounted_fs_id).* orelse
            @panic("Invalid open file");

        switch (self.dir_ent.filetype) {
            .directory => @panic("TODO: directory write"),
            .regular => {
                return if (fs.skeleton.operations) |ops|
                    // if the fs skeleton has a write function defined we use that to read the
                    // contents of the file, and whether the page cache is enabled for the fs we
                    // use it as a middleman (regular filesystems like ext{2,3,4} would use this)
                    return if (fs.skeleton.flags.has_page_cache)
                        genericWriteRegular(fs, self.dir_ent.regular(), buff, offset)
                    else
                        ops.write(fs.internal_data, self.dir_ent.inode, buff, offset)
                else if (fs.skeleton.flags.has_page_cache)
                    // otherwise if the page cache is enabled we use it for storing the file
                    // contents without writeback to a block device (ramfs would use this)
                    genericWriteRegular(fs, self.dir_ent.regular(), buff, offset)
                else blk: {
                    // otherwise the entry (all entries in the fs) must be a RegularUnique meaning
                    // all of them have different fs operations (devfs, procfs would use this)
                    const regular_unique: *FileSystemCache.RegularUnique = @fieldParentPtr(
                        "common",
                        self.dir_ent,
                    );
                    break :blk regular_unique.operations.write(
                        regular_unique.internal_data,
                        self.dir_ent.inode,
                        buff,
                        offset,
                    );
                };
            },
        }
    }
};

pub fn walkUntilLastComponent(
    mount_table: *MountTable,
    start_dir: ?OpenFile,
    path_str: []const u8,
    out_fs: **FileSystem,
    out_parent_dir: **FileSystemCache.Directory,
    out_last_component: *[]const u8,
) !void {
    // TODO: LOCKING

    // TODO: clean name (VERY IMPORTANT!!!!)

    if (path_str.len == 0) return error.InvalidPath;

    // TODO: consider saving the root mapping in MountTable for easier access

    var current_fs: *FileSystem = undefined;
    var current_dir: *FileSystemCache.Directory = undefined;
    if (start_dir) |dir| {
        current_fs = global_file_system_table.getById(dir.mounted_fs_id).* orelse
            @panic("Invalid open file");
        current_dir = dir.dir_ent.directory();
    } else {
        const root_mount = mount_table.mounts orelse @panic("No root mount");
        current_fs = root_mount.file_system;
        current_dir = &current_fs.fs_cache.root_directory;
    }

    out_fs.* = current_fs;
    // TODO: out_parent_dir can be null?

    var path = if (start_dir == null)
        try Path.fromStringWithSlash(path_str)
    else
        try Path.fromStringWithoutSlash(path_str);

    while (path.next()) |path_element| {
        const traversed_path = path.alreadyTraversed();
        const is_last_component = path.reachedEnd();

        if (mount_table.findMount(traversed_path).*) |mount| {
            current_fs = mount.file_system;
            current_dir = &current_fs.fs_cache.root_directory;
            out_fs.* = current_fs;
            continue;
        }

        const dir_entry_ptr = current_dir.lookup(path_element);
        if (is_last_component) {
            out_last_component.* = path_element;
            out_parent_dir.* = current_dir;
        } else {
            if (dir_entry_ptr.*) |dir_entry| {
                switch (dir_entry.filetype) {
                    .regular => return error.EntryNotFound,
                    .directory => current_dir = dir_entry.directory(),
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

pub fn createDirectory(mount_table: *MountTable, inode: Inode, path_str: []const u8) !void {
    var fs: *FileSystem = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(mount_table, null, path_str, &fs, &dir, &last_component);
    try dir.createDirectory(last_component, inode);
}

pub fn createRegularFile(mount_table: *MountTable, inode: Inode, path_str: []const u8) !void {
    var fs: *FileSystem = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(mount_table, null, path_str, &fs, &dir, &last_component);
    try dir.createRegular(last_component, inode);
}

pub fn createRegularUniqueFile(
    mount_table: *MountTable,
    inode: Inode,
    path_str: []const u8,
    internal_data: ?*anyopaque,
    operations: *const FileSystemSkeleton.Operations,
) !void {
    var fs: *FileSystem = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(mount_table, null, path_str, &fs, &dir, &last_component);
    try dir.createRegularUnique(last_component, inode, internal_data, operations);
}

// TODO: ERRORS
pub fn openFile(mount_table: *MountTable, start_dir: ?OpenFile, path_str: []const u8) !OpenFile {
    var mounted_fs: *FileSystem = undefined;
    var dir: *FileSystemCache.Directory = undefined;
    var last_component: []const u8 = &.{};

    try walkUntilLastComponent(
        mount_table,
        start_dir,
        path_str,
        &mounted_fs,
        &dir,
        &last_component,
    );

    const dir_entry = dir.lookup(last_component).* orelse return error.EntryNotFound;
    // TODO: LOCKING

    // TODO: if the path_str points to a mount this wouldnt work probably?

    dir_entry.reference_count += 1;
    return OpenFile{
        .mounted_fs_id = mounted_fs.id,
        .dir_ent = dir_entry,
    };
}

pub fn dumpTree(mount_table: *MountTable) void {
    // TODO: this only prints the root mount
    const root_mount = mount_table.mounts orelse @panic("No root mount");
    const root_fs = root_mount.file_system;
    const root_dir = &root_fs.fs_cache.root_directory;
    dumpDirectory(root_fs, root_dir, 0);
}

pub fn dumpDirectory(fs: *FileSystem, dir: *FileSystemCache.Directory, depth: usize) void {
    const is_special = fs.skeleton.isSpecial();
    // TODO: buffer likely too small
    const space_count = depth * 4;
    var indent_buffer: [512]u8 = undefined;
    for (0..space_count) |i| indent_buffer[i] = ' ';

    var dir_ent_ptr = dir.entries;
    while (dir_ent_ptr) |dir_ent| : (dir_ent_ptr = dir_ent.next) {
        switch (dir_ent.filetype) {
            .regular => {
                if (is_special) {
                    std.log.info("{s}{s} [special]", .{
                        indent_buffer[0..space_count],
                        dir_ent.name,
                    });
                } else {
                    std.log.info("{s}{s} [{} bytes]", .{
                        indent_buffer[0..space_count],
                        dir_ent.name,
                        dir_ent.regular().size,
                    });
                }
            },
            .directory => {
                std.log.info("{s}{s}:", .{ indent_buffer[0..space_count], dir_ent.name });
                dumpDirectory(fs, dir_ent.directory(), depth + 1);
            },
        }
    }
}

/// Initialize the Virtual File System.
pub fn init() void {
    Mount.cache = slab_allocator.createObjectCache(Mount);
    FileSystem.cache = slab_allocator.createObjectCache(FileSystem);
    FileSystemCache.Regular.cache = slab_allocator.createObjectCache(FileSystemCache.Regular);
    FileSystemCache.RegularUnique.cache = slab_allocator.createObjectCache(
        FileSystemCache.RegularUnique,
    );
    FileSystemCache.Directory.cache = slab_allocator.createObjectCache(FileSystemCache.Directory);
    PageCache.init();
}
