//! https://git.kernel.org/pub/scm/linux/kernel/git/legion/kbd.git/tree/src/psf.h?id=82dd58358bd341f8ad71155a53a561cf311ac974
//! https://aeb.win.tue.nl/linux/kbd/font-formats-1.html

const std = @import("std");
const framebuffer = @import("framebuffer.zig");

const font = @embedFile("lat9w-16.psfu");

// in little endian
const psf1_magic = 0x04_36;
const psf2_magic = 0x86_4a_b5_72;

const PSF1Header = extern struct {
    magic: u16,
    psf_font_mode: Mode,
    glyph_size: u8,

    const Mode = packed struct(u8) {
        glyph_count_512: bool,
        has_unicode_table: bool,
        reserved: u6,
    };
};

const PSF2Header = extern struct {
    magic: u32,
    version: u32,
    header_size: u32,
    flags: Flags,
    glyph_count: u32,
    glyph_size: u32,
    height: u32,
    width: u32,

    const Flags = packed struct(u32) {
        has_unicode_table: bool,
        reserved: u31,
    };
};

const PCFont = struct {
    glyph_size: usize,
    glyph_count: usize,
    width: u32,
    height: u32,
    glyph_table: []const u8,
};

var pc_font: PCFont = undefined;

pub fn init() void {
    const psf2: *const PSF2Header = @ptrCast(@alignCast(font));
    if (psf2.magic != psf2_magic) {
        const psf1: *const PSF1Header = @ptrCast(@alignCast(font));
        const glyph_table: []const u8 = font[@sizeOf(PSF1Header)..];

        pc_font = .{
            .glyph_size = psf1.glyph_size,
            .glyph_count = 256,
            .width = 8,
            .height = psf1.glyph_size,
            .glyph_table = glyph_table,
        };
    } else {
        const glyph_table: []const u8 = font[psf2.header_size..];

        pc_font = .{
            .glyph_size = psf2.glyph_size,
            .glyph_count = psf2.glyph_count,
            .width = psf2.width,
            .height = psf2.height,
            .glyph_table = glyph_table,
        };
    }
}

const white = framebuffer.PixelRGBA{
    .red = 255,
    .green = 255,
    .blue = 255,
    .alpha = 255,
};

const black = framebuffer.PixelRGBA{
    .red = 0,
    .green = 0,
    .blue = 0,
    .alpha = 0,
};

pub fn displayChararcter(fb: *framebuffer.Framebuffer, x: usize, y: usize, ch: u8) void {
    // TODO: format

    const fb_mem: [*]framebuffer.PixelRGBA = @ptrCast(@alignCast(fb.active_display.memory));

    const glyph_table_base = ch * pc_font.glyph_size;
    var glyph_table_off: usize = 0;

    const scale = 2;
    const base_x = x * pc_font.width * scale;
    const base_y = y * pc_font.height * scale;

    var glyph_y: usize = 0;
    while (glyph_y < pc_font.height) : (glyph_y += 1) {
        var glyph_x: usize = 0;
        while (glyph_x < pc_font.width) : (glyph_x += 1) {
            if (glyph_x != 0 and glyph_x % 8 == 0) glyph_table_off += 1;
            const current_glyph_byte = pc_font.glyph_table[glyph_table_base + glyph_table_off];

            const bit = std.math.shr(u8, 0b1000_0000, glyph_x % 8);

            const fb_y = base_y + glyph_y * scale;
            const fb_x = base_x + glyph_x * scale;

            const color = if (current_glyph_byte & bit > 0) white else black;

            for (0..scale) |scale_y| {
                for (0..scale) |scale_x| {
                    fb_mem[(fb_y + scale_y) * fb.active_display.width + fb_x + scale_x] = color;
                }
            }
        }

        glyph_table_off += 1;
    }
}
