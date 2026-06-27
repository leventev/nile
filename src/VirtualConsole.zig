const std = @import("std");
const tty = @import("tty.zig");
const framebuffer = @import("framebuffer.zig");
const pc_font = @import("pc_font.zig");

const VirtualConsole = @This();

framebuffer_backing: *framebuffer.Framebuffer,
columns: usize,
rows: usize,
output_buffer: []u8,
output_buffer_index: usize,

pub const operations = tty.TTYDevice.Driver.Operations{
    .write = write,
};

fn write(tty_device: *tty.TTYDevice, buff: []const u8) void {
    // TODO: wrapping

    const self: *VirtualConsole = @ptrCast(@alignCast(tty_device.driver.internal_data));

    for (buff) |ch| {
        self.output_buffer[self.output_buffer_index] = ch;
        self.output_buffer_index += 1;
    }

    self.redraw();
}

pub fn init(self: *VirtualConsole, gpa: std.mem.Allocator, fb: *framebuffer.Framebuffer) !void {
    self.framebuffer_backing = fb;
    self.columns = self.framebuffer_backing.active_display.width / pc_font.loaded_font.width;
    self.rows = self.framebuffer_backing.active_display.height / pc_font.loaded_font.height;

    self.output_buffer = try gpa.alloc(u8, self.columns * self.rows);
    @memset(self.output_buffer, 0);
    self.output_buffer_index = 0;
}

pub fn redraw(self: *VirtualConsole) void {
    for (0..self.rows) |row| {
        for (0..self.columns) |column| {
            const idx = row * self.columns + column;
            const ch = self.output_buffer[idx];
            if (ch == 0) continue;
            pc_font.displayChararcter(self.framebuffer_backing, column, row, ch);
        }
    }

    self.framebuffer_backing.flush();
}

// fn drawCursor() void {
//     const x = line_buffer_written * 16;
//     framebuffer.fillRect(x, 0, 16, 32, .{
//         .alpha = 255,
//         .red = 255,
//         .green = 255,
//         .blue = 255,
//     });
// }
