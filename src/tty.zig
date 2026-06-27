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
            self.input_buffer[idx] = ch;
            self.input_buffer_write_index +%= 1;
            self.input_buffer_written += 1;
        }

        if (self.flags.echo) {
            self.driver.operations.write(self, chars);
        }
    }

    pub const Driver = struct {
        internal_data: *anyopaque,
        operations: *const Operations,

        pub const Operations = struct {
            write: *const fn (tty_device: *TTYDevice, buff: []const u8) void,
        };
    };

    // fn reprintLine(self: *TTYDevice) void {
    //     const rem = 80 - self.line_buffer_written;
    //     framebuffer.printText(0, 0, self.input_buffer[0..self.line_buffer_written]);
    //     for (0..rem) |i| {
    //         framebuffer.displayCharacter(self.line_buffer_written + i, 0, ' ');
    //     }
    //     // drawCursor();
    //     framebuffer.flush();
    // }
};

const tty_devfs_operations = DeviceFilesystem.Device.Operations{
    .read = ttyDevfsRead,
    .write = ttyDevfsWrite,
};

const buffer_size = 4096;

// TODO: store all TTY devices

var tty_counter: usize = 0;

pub fn createTTYDevice(
    gpa: std.mem.Allocator,
    devfs: *DeviceFilesystem,
    internal_data: *anyopaque,
    operations: *const TTYDevice.Driver.Operations,
) !*TTYDevice {
    const tty_dev = try gpa.create(TTYDevice);

    tty_dev.input_buffer = try gpa.alloc(u8, buffer_size);
    tty_dev.input_buffer_read_index = 0;
    tty_dev.input_buffer_write_index = 0;
    tty_dev.input_buffer_written = 0;
    tty_dev.driver.internal_data = internal_data;
    tty_dev.driver.operations = operations;

    const filename = try std.fmt.allocPrint(gpa, "tty{}", .{tty_counter});

    try DeviceFilesystem.create(devfs, filename, &tty_devfs_operations, tty_dev);

    tty_counter += 1;

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
    tty.driver.operations.write(tty, buff);

    return 0;
}
