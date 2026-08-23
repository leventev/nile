//! https://www.linusakesson.net/programming/tty/
//! https://docs.kernel.org/driver-api/tty/index.html
//! Chapter 62 and 64 of the linux programming interface book

const std = @import("std");
const framebuffer = @import("framebuffer.zig");
const input = @import("input.zig");
const vfs = @import("vfs.zig");
const DeviceFilesystem = @import("DeviceFilesystem.zig");
const sync = @import("sync.zig");

const log = std.log.scoped(.tty);

// TODO: maybe abstract a ring buffer
pub const TTYDevice = struct {
    input_buffer: []u8,
    input_buffer_write_index: usize,
    input_buffer_read_index: usize,
    input_buffer_written: usize,
    input_buffer_newline_idx: ?usize,
    input_buffer_newline_semaphore: sync.Semaphore,
    driver: Driver,
    flags: Flags,

    pub const Flags = packed struct(u64) {
        echo: bool,
        reserved: u63,
    };

    pub fn writeToInputBuffer(self: *TTYDevice, chars: []const u8) void {
        var buff: [256]u8 = undefined;
        // TODO:
        std.debug.assert(chars.len <= buff.len);
        var buff_idx: usize = 0;

        for (chars) |ch| {
            const idx = self.input_buffer_write_index % self.input_buffer.len;
            switch (ch) {
                0x8 => { // backspace
                    if (self.input_buffer_written == 0) continue;
                    self.input_buffer[idx - 1] = ' ';
                    self.input_buffer_write_index -%= 1;
                    self.input_buffer_written -= 1;
                },
                else => {
                    if (ch == '\n' and self.input_buffer_newline_idx == null) {
                        self.input_buffer_newline_semaphore.add();
                        self.input_buffer_newline_idx = idx;
                    }

                    self.input_buffer[idx] = ch;
                    self.input_buffer_write_index +%= 1;
                    self.input_buffer_written += 1;
                },
            }

            buff[buff_idx] = ch;
            buff_idx += 1;
        }

        if (self.flags.echo) {
            self.driver.operations.writeString(self, buff[0..buff_idx]);
        }
    }

    pub const Driver = struct {
        internal_data: *anyopaque,
        operations: *const Operations,

        pub const Operations = struct {
            writeString: *const fn (tty_device: *TTYDevice, string: []const u8) void,
        };
    };
};

const tty_devfs_operations = vfs.FileSystemSkeleton.Operations{
    .read = ttyDevfsRead,
    .write = ttyDevfsWrite,
};

const buffer_size = 4096;

// TODO: store all TTY devices

pub fn createTTYDevice(
    gpa: std.mem.Allocator,
    devfs: *DeviceFilesystem,
    internal_data: *anyopaque,
    operations: *const TTYDevice.Driver.Operations,
    filename: []const u8,
) !*TTYDevice {
    const tty_dev = try gpa.create(TTYDevice);

    tty_dev.* = .{
        // TODO: errderef
        .input_buffer = try gpa.alloc(u8, buffer_size),
        .input_buffer_read_index = 0,
        .input_buffer_write_index = 0,
        .input_buffer_written = 0,
        .input_buffer_newline_idx = null,
        .input_buffer_newline_semaphore = .default,
        .driver = .{
            .internal_data = internal_data,
            .operations = operations,
        },
        .flags = .{
            .echo = true,
            .reserved = 0,
        },
    };

    try DeviceFilesystem.createRegular(devfs, filename, tty_dev, &tty_devfs_operations);

    return tty_dev;
}

fn ttyDevfsRead(
    internal_data: ?*anyopaque,
    inode: vfs.Inode,
    buff: []u8,
    offset: usize,
) vfs.FileSystemError!usize {
    _ = inode;
    _ = offset;

    const tty: *TTYDevice = @ptrCast(@alignCast(internal_data orelse unreachable));

    // block
    tty.input_buffer_newline_semaphore.sub();

    const max_read_size = @min(buff.len, tty.input_buffer_written);

    var read_size: usize = 0;
    while (tty.input_buffer_newline_idx) |newline_idx| {
        const remaining = max_read_size - read_size;
        const line_size = newline_idx + 1;

        if (remaining < line_size) {
            tty.input_buffer_newline_idx = newline_idx - remaining;
            read_size += remaining;
            break;
        }

        var read_idx = tty.input_buffer_read_index % tty.input_buffer.len;
        const write_idx = tty.input_buffer_write_index % tty.input_buffer.len;
        tty.input_buffer_newline_idx = null;
        while (read_idx < write_idx) : (read_idx = (read_idx + 1) % tty.input_buffer.len) {
            if (tty.input_buffer[read_idx] != '\n') continue;
            tty.input_buffer_newline_idx = read_idx;
            break;
        }

        read_size += line_size;
    }

    var buff_idx: usize = 0;
    while (buff_idx < read_size) : (buff_idx += 1) {
        const read_idx = tty.input_buffer_read_index % tty.input_buffer.len;
        buff[buff_idx] = tty.input_buffer[read_idx];
        tty.input_buffer_read_index +%= 1;
    }

    tty.input_buffer_written -= read_size;

    return read_size;
}

fn ttyDevfsWrite(
    internal_data: ?*anyopaque,
    inode: vfs.Inode,
    buff: []const u8,
    offset: usize,
) vfs.FileSystemError!usize {
    _ = inode;

    if (offset != 0) {
        log.warn("offset != 0 ({})", .{offset});
        return 0;
    }

    const tty: *TTYDevice = @ptrCast(@alignCast(internal_data orelse unreachable));
    tty.driver.operations.writeString(tty, buff);

    return 0;
}
