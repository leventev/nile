const std = @import("std");
const tty = @import("tty.zig");
const framebuffer = @import("framebuffer.zig");
const pc_font = @import("pc_font.zig");

const VirtualConsole = @This();

id: usize,
framebuffer_backing: *framebuffer.Framebuffer,
columns: usize,
rows: usize,
output_buffer: []u8,
output_buffer_index: usize,

const font_scale = 2;

pub const operations = tty.TTYDevice.Driver.Operations{
    .writeChar = writeChar,
};

fn writeChar(tty_device: *tty.TTYDevice, ch: u8) void {
    // TODO: wrapping

    const self: *VirtualConsole = @ptrCast(@alignCast(tty_device.driver.internal_data));

    switch (ch) {
        '\n' => {
            self.eraseCursor(self.output_buffer_index);

            self.output_buffer_index = std.mem.alignForwardAnyAlign(
                usize,
                self.output_buffer_index,
                self.columns,
            );
        },
        0x8 => {
            self.eraseCursor(self.output_buffer_index);

            self.output_buffer_index -= 1;
            self.output_buffer[self.output_buffer_index] = ' ';
            self.redrawAtPosition(self.output_buffer_index);
        },
        else => {
            // TODO:only add valid characters
            self.output_buffer[self.output_buffer_index] = ch;
            self.redrawAtPosition(self.output_buffer_index);
            self.output_buffer_index +%= 1;
        },
    }

    self.drawCursor();
    self.framebuffer_backing.flush();
}

pub fn init(self: *VirtualConsole, gpa: std.mem.Allocator, fb: *framebuffer.Framebuffer) !void {
    self.framebuffer_backing = fb;
    self.columns = self.framebuffer_backing.active_display.width / pc_font.loaded_font.width;
    self.rows = self.framebuffer_backing.active_display.height / pc_font.loaded_font.height;

    self.output_buffer = try gpa.alloc(u8, self.columns * self.rows);
    @memset(self.output_buffer, 0);
    self.output_buffer_index = 0;
}

fn redrawAtPosition(self: *VirtualConsole, index: usize) void {
    const ch = self.output_buffer[index];
    const row = index / self.columns;
    const column = index % self.columns;

    pc_font.displayChararcter(self.framebuffer_backing, column, row, ch, font_scale);
}

pub fn redraw(self: *VirtualConsole) void {
    self.framebuffer_backing.fillRect(
        0,
        0,
        self.framebuffer_backing.active_display.width,
        self.framebuffer_backing.active_display.height,
        .{ .alpha = 255, .red = 0, .green = 0, .blue = 0 },
    );
    for (0..self.rows) |row| {
        for (0..self.columns) |column| {
            const idx = row * self.columns + column;
            const ch = self.output_buffer[idx];
            if (ch == 0) continue;
            pc_font.displayChararcter(self.framebuffer_backing, column, row, ch, font_scale);
        }
    }

    self.drawCursor();

    self.framebuffer_backing.flush();
}

fn colorFillPosition(self: *VirtualConsole, pos: usize, color: framebuffer.PixelRGBA) void {
    const row = pos / self.columns;
    const column = pos % self.columns;
    const x = column * pc_font.loaded_font.width * font_scale;
    const y = row * pc_font.loaded_font.height * font_scale;
    framebuffer.fillRect(
        x,
        y,
        pc_font.loaded_font.width * font_scale,
        pc_font.loaded_font.height * font_scale,
        color,
    );
}

fn eraseCursor(self: *VirtualConsole, pos: usize) void {
    self.colorFillPosition(
        pos,
        .{ .alpha = 255, .red = 0, .green = 0, .blue = 0 },
    );
}

fn drawCursor(self: *VirtualConsole) void {
    self.colorFillPosition(
        self.output_buffer_index,
        .{ .alpha = 255, .red = 255, .green = 255, .blue = 255 },
    );
}
