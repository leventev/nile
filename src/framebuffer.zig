const std = @import("std");
const pc_font = @import("pc_font.zig");
const DeviceFilesystem = @import("DeviceFilesystem.zig");

const log = std.log.scoped(.framebuffer);

pub const PixelFormat = enum {
    rgba,
    xrgb,
};

pub const PixelRGBA = packed struct(u32) {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
};

/// Describes a framebuffer device.
pub const Framebuffer = struct {
    active_display: Display,
    operations: Operations,
    private_data: *anyopaque,

    pub fn fillRect(
        self: *Framebuffer,
        start_x: usize,
        start_y: usize,
        width: usize,
        height: usize,
        color: PixelRGBA,
    ) void {
        std.debug.assert(start_x + width < self.active_display.width);
        std.debug.assert(start_y + height < self.active_display.height);
        // TODO: format

        const pixels: [*]PixelRGBA = @ptrCast(@alignCast(self.active_display.memory));
        var y = start_y;
        while (y < start_y + height) : (y += 1) {
            var x = start_x;
            while (x < start_x + width) : (x += 1) {
                // log.debug("x: {} y: {} idx: {}", .{ x, y, y * self.active_display.width + x });
                pixels[y * self.active_display.width + x] = color;
            }
        }
    }

    pub fn flush(self: *Framebuffer) void {
        self.operations.flush(self.private_data);
    }

    pub const Display = struct {
        /// Width of the framebuffer.
        width: usize,

        /// Height of the frambuffer.
        height: usize,

        /// The format of the pixels, basically how to interpret the memory.
        format: PixelFormat,

        /// The memory of the frambuffer.
        memory: *anyopaque,
    };

    pub const Operations = struct {
        /// TODO: be able to select format
        setup: *const fn (private_data: *anyopaque, display_data: *Display) bool,

        /// Flushes the updates to the display.
        flush: *const fn (private_data: *anyopaque) void,
    };
};

const max_framebuffers = 4;
var framebuffers: [max_framebuffers]Framebuffer = undefined;
var framebuffer_count: usize = 0;

fn devfsRead(private_data: *anyopaque, buff: []u8, offset: usize) usize {
    _ = private_data;
    _ = buff;
    _ = offset;
    return 0;
}

fn devfsWrite(private_data: *anyopaque, buff: []const u8, offset: usize) usize {
    _ = private_data;
    _ = buff;
    _ = offset;
    return 0;
}

const devfs_ops = DeviceFilesystem.Device.Operations{
    .read = devfsRead,
    .write = devfsWrite,
};

pub fn addFramebuffer(
    devfs: *DeviceFilesystem,
    ops: Framebuffer.Operations,
    private_data: *anyopaque,
) bool {
    std.debug.assert(framebuffer_count < max_framebuffers);

    const fb: *Framebuffer = &framebuffers[framebuffer_count];
    fb.operations = ops;
    fb.private_data = private_data;

    const ok = ops.setup(private_data, &fb.active_display);
    if (!ok) {
        log.warn("Failed to add framebuffer", .{});
        return false;
    }

    log.debug("added framebuffer with {}x{} size, {} format", .{
        fb.active_display.width,
        fb.active_display.height,
        fb.active_display.format,
    });

    framebuffer_count += 1;

    // TODO: multiple framebuffer numbers
    devfs.create("framebuffer", &devfs_ops, fb) catch @panic("TODO");

    return true;
}

pub fn fillRect(
    start_x: usize,
    start_y: usize,
    width: usize,
    height: usize,
    color: PixelRGBA,
) void {
    // TODO: LOCKIGN
    std.debug.assert(framebuffer_count > 0);

    const fb = &framebuffers[0];
    fb.fillRect(start_x, start_y, width, height, color);
}

pub fn flush() void {
    // TODO: LOCKIGN
    std.debug.assert(framebuffer_count > 0);

    const fb = &framebuffers[0];
    fb.flush();
}

pub fn displayCharacter(x: usize, y: usize, ch: u8) void {
    std.debug.assert(framebuffer_count > 0);

    const fb = &framebuffers[0];
    pc_font.displayChararcter(fb, x, y, ch);
}

pub fn printText(x: usize, y: usize, str: []const u8) void {
    for (str, 0..) |ch, i| {
        displayCharacter(x + i, y, ch);
    }
}
