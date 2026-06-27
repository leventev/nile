//! https://www.linusakesson.net/programming/tty/
//! https://docs.kernel.org/driver-api/tty/index.html
//! Chapter 62 and 64 of the linux programming interface book

const std = @import("std");
const framebuffer = @import("framebuffer.zig");
const input = @import("input.zig");
const DeviceFilesystem = @import("DeviceFilesystem.zig");

const log = std.log.scoped(.tty);

// TODO: maybe abstract a ring buffer
pub const TTYDevice = struct {
    input_buffer: []u8,
    input_buffer_write_index: usize,
    input_buffer_read_index: usize,
    input_buffer_written: usize,
    driver: Driver,
    flags: Flags,

    pub const Flags = packed struct(u64) {
        echo: bool,
        reserved: u63,
    };

    pub fn writeToInputBuffer(self: *TTYDevice, chars: []const u8) void {
        for (chars) |ch| {
            const idx = self.input_buffer_write_index % self.input_buffer.len;
            switch (ch) {
                0x8 => {
                    if (self.input_buffer_written == 0) continue;
                    self.input_buffer[idx - 1] = ' ';
                    self.input_buffer_write_index -%= 1;
                    self.input_buffer_written -= 1;
                },
                else => {
                    self.input_buffer[idx] = ch;
                    self.input_buffer_write_index +%= 1;
                    self.input_buffer_written += 1;
                },
            }
            if (self.flags.echo) {
                self.driver.operations.writeChar(self, ch);
            }
        }
    }

    pub const Driver = struct {
        internal_data: *anyopaque,
        operations: *const Operations,

        pub const Operations = struct {
            writeChar: *const fn (tty_device: *TTYDevice, ch: u8) void,
        };
    };
};

const tty_devfs_operations = DeviceFilesystem.Device.Operations{
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

    tty_dev.input_buffer = try gpa.alloc(u8, buffer_size);
    tty_dev.input_buffer_read_index = 0;
    tty_dev.input_buffer_write_index = 0;
    tty_dev.input_buffer_written = 0;
    tty_dev.driver.internal_data = internal_data;
    tty_dev.driver.operations = operations;
    tty_dev.flags = .{
        .echo = true,
        .reserved = 0,
    };

    try DeviceFilesystem.create(devfs, filename, &tty_devfs_operations, tty_dev);

    return tty_dev;
}

fn ttyDevfsRead(internal_data: *anyopaque, buff: []u8, offset: usize) usize {
    if (offset != 0) {
        log.warn("offset != 0 ({})", .{offset});
        return 0;
    }

    const tty: *TTYDevice = @ptrCast(@alignCast(internal_data));
    const read_size = @min(buff.len, tty.input_buffer_written);

    var buff_idx: usize = 0;
    while (tty.input_buffer_read_index != tty.input_buffer_write_index) {
        const read_idx = tty.input_buffer_read_index % tty.input_buffer.len;
        buff[buff_idx] = tty.input_buffer[read_idx];

        buff_idx += 1;
        tty.input_buffer_read_index +%= 1;
    }

    std.debug.assert(buff_idx == read_size);

    tty.input_buffer_written -= read_size;

    return read_size;
}

fn ttyDevfsWrite(internal_data: *anyopaque, buff: []const u8, offset: usize) usize {
    if (offset != 0) {
        log.warn("offset != 0 ({})", .{offset});
        return 0;
    }

    const tty: *TTYDevice = @ptrCast(@alignCast(internal_data));
    for (buff) |ch| {
        tty.driver.operations.writeChar(tty, ch);
    }

    return 0;
}
