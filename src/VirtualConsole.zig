const std = @import("std");
const tty = @import("tty.zig");
const framebuffer = @import("framebuffer.zig");
const pc_font = @import("pc_font.zig");

const VirtualConsole = @This();

id: usize,
framebuffer_backing: *framebuffer.Framebuffer,
columns: usize,
rows: usize,
output_buffer_index: usize,

const font_scale = 2;

pub const operations = tty.TTYDevice.Driver.Operations{
    .writeString = writeString,
};

fn writeString(tty_device: *tty.TTYDevice, string: []const u8) void {
    // TODO: wrapping

    const self: *VirtualConsole = @ptrCast(@alignCast(tty_device.driver.internal_data));

    for (string) |ch| {
        switch (ch) {
            '\n' => {
                self.eraseCursor(self.output_buffer_index);

                self.output_buffer_index = std.mem.alignForwardAnyAlign(
                    usize,
                    self.output_buffer_index,
                    self.columns,
                );
            },
            0x8 => { // backspace
                self.eraseCursor(self.output_buffer_index);
                if (self.output_buffer_index == 0) return;

                self.output_buffer_index -= 1;
                // self.output_buffer[self.output_buffer_index] = ' ';
                self.redrawAtPosition(self.output_buffer_index, ' ');
            },
            else => {
                if (self.output_buffer_index >= self.columns * self.rows)
                    self.scroll();

                // TODO:only add valid characters
                self.redrawAtPosition(self.output_buffer_index, ch);
                self.output_buffer_index +%= 1;
            },
        }
    }

    self.drawCursor();
    self.framebuffer_backing.flush();
}

fn drawCharacter(self: *VirtualConsole, character: u8) void {
    self.redrawAtPosition(self.output_buffer_index, character);
}

pub fn init(self: *VirtualConsole, gpa: std.mem.Allocator, fb: *framebuffer.Framebuffer) !void {
    self.framebuffer_backing = fb;
    self.columns = self.framebuffer_backing.active_display.width / (pc_font.loaded_font.width * font_scale);
    self.rows = self.framebuffer_backing.active_display.height / (pc_font.loaded_font.height * font_scale);

    _ = gpa;
    self.output_buffer_index = 0;
}

fn redrawAtPosition(self: *VirtualConsole, index: usize, ch: u8) void {
    const row = index / self.columns;
    const column = index % self.columns;

    pc_font.displayChararcter(self.framebuffer_backing, column, row, ch, font_scale);
}

pub fn scroll(self: *VirtualConsole) void {
    self.output_buffer_index = (self.rows - 1) * self.columns;

    const row_pixel_height = pc_font.loaded_font.height * font_scale;
    const disp = &self.framebuffer_backing.active_display;
    const fb_mem: [*]framebuffer.PixelRGBA = @ptrCast(@alignCast(disp.memory));
    @memmove(
        fb_mem[0 .. (disp.height - row_pixel_height) * disp.width],
        fb_mem[row_pixel_height * disp.width .. disp.height * disp.width],
    );
    @memset(
        fb_mem[(disp.height - row_pixel_height) * disp.width .. disp.height * disp.width],
        framebuffer.PixelRGBA{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
    );
}

pub fn clear(self: *VirtualConsole) void {
    const disp = &self.framebuffer_backing.active_display;
    const fb_mem: [*]framebuffer.PixelRGBA = @ptrCast(@alignCast(disp.memory));
    @memset(
        fb_mem[0 .. disp.height * disp.width],
        framebuffer.PixelRGBA{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
    );
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
