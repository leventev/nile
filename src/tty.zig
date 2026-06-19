const std = @import("std");
const framebuffer = @import("framebuffer.zig");
const input = @import("input.zig");

const log = std.log.scoped(.tty);

fn keyToChar(ev: input.KeyEvent) ?u8 {
    // TODO
    return switch (ev.key) {
        .key_1 => '1',
        .key_2 => '2',
        .key_3 => '3',
        .key_4 => '4',
        .key_5 => '5',
        .key_6 => '6',
        .key_7 => '7',
        .key_8 => '8',
        .key_9 => '9',
        .key_0 => '0',
        .key_q => 'q',
        .key_w => 'w',
        .key_e => 'e',
        .key_r => 'r',
        .key_t => 't',
        .key_y => 'y',
        .key_u => 'u',
        .key_i => 'i',
        .key_o => 'o',
        .key_p => 'p',
        .key_a => 'a',
        .key_s => 's',
        .key_d => 'd',
        .key_f => 'f',
        .key_g => 'g',
        .key_h => 'h',
        .key_j => 'j',
        .key_k => 'k',
        .key_l => 'l',
        .key_z => 'z',
        .key_x => 'x',
        .key_c => 'c',
        .key_v => 'v',
        .key_b => 'b',
        .key_n => 'n',
        .key_m => 'm',
        .key_space => ' ',
        .key_semicolon => ';',
        .key_dot => '.',
        .key_comma => ',',
        else => {
            log.warn("ignored key: {}", .{ev.key});
            return null;
        },
    };
}

var line_buffer: [80]u8 = undefined;
var line_buffer_written: usize = 0;

fn writeChar(ch: u8) void {
    line_buffer[line_buffer_written] = ch;
    line_buffer_written += 1;
    reprintLine();
}

fn backspace() void {
    if (line_buffer_written == 0) return;
    line_buffer_written -= 1;
    reprintLine();
}

fn reprintLine() void {
    const rem = 80 - line_buffer_written;
    framebuffer.printText(0, 0, line_buffer[0..line_buffer_written]);
    for (0..rem) |i| {
        framebuffer.displayCharacter(line_buffer_written + i, 0, ' ');
    }
    drawCursor();
    framebuffer.flush();
}

fn drawCursor() void {
    const x = line_buffer_written * 16;
    framebuffer.fillRect(x, 0, 16, 32, .{
        .alpha = 255,
        .red = 255,
        .green = 255,
        .blue = 255,
    });
}

var shift_enabled = false;

pub fn keyEvent() void {
    while (input.readKeyEvent()) |ev| {
        if (ev.event_type == .released) {
            if (ev.key == .key_leftshift or ev.key == .key_rightshift) {
                shift_enabled = false;
            }
            continue;
        }

        switch (ev.key) {
            .key_backspace => backspace(),
            .key_leftshift, .key_rightshift => shift_enabled = true,
            else => {
                const raw_ch = keyToChar(ev) orelse continue;
                const ch = if (shift_enabled)
                    std.ascii.toUpper(raw_ch)
                else
                    raw_ch;

                writeChar(ch);
            },
        }
    }
}
