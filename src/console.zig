const std = @import("std");
const tty = @import("tty.zig");
const VirtualConsole = @import("VirtualConsole.zig");
const DeviceFilesystem = @import("DeviceFilesystem.zig");
const framebuffer = @import("framebuffer.zig");
const input = @import("input.zig");

const log = std.log.scoped(.console);

// TODO: tty device count config
const tty_device_count = 4;
var tty_devices: [tty_device_count]*tty.TTYDevice = undefined;
var current_tty_device: usize = 0;

pub fn init(
    gpa: std.mem.Allocator,
    devfs: *DeviceFilesystem,
    fb: *framebuffer.Framebuffer,
) !void {

    // TODO: errdefer cleanup
    for (0..tty_device_count) |i| {
        const virtual_console = try gpa.create(VirtualConsole);
        virtual_console.id = i;
        try virtual_console.init(gpa, fb);

        const filename = try std.fmt.allocPrint(gpa, "tty{}", .{virtual_console.id});

        tty_devices[i] = try tty.createTTYDevice(
            gpa,
            devfs,
            virtual_console,
            &VirtualConsole.operations,
            filename,
        );
    }
}

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
        .key_backspace => 0x8,
        else => {
            log.warn("ignored key: {}", .{ev.key});
            return null;
        },
    };
}

// TODO: there is probably a better way to do this with @Type
var key_states: [@intFromEnum(input.EvdevKeyEventCode.max)]bool = @splat(false);

var shift_enabled = false;

pub fn keyEvent() void {
    const current_dev = tty_devices[current_tty_device];

    while (input.readKeyEvent()) |ev| {
        if (ev.event_type == .released) {
            key_states[@intFromEnum(ev.key)] = false;
            continue;
        }

        key_states[@intFromEnum(ev.key)] = true;

        switch (ev.key) {
            // TODO:
            .key_f1, .key_f2, .key_f3, .key_f4, .key_f5, .key_f6 => {
                const f_num = @intFromEnum(ev.key) - @intFromEnum(input.EvdevKeyEventCode.key_f1);
                const ctrl = key_states[@intFromEnum(input.EvdevKeyEventCode.key_leftctrl)];
                const shift = key_states[@intFromEnum(input.EvdevKeyEventCode.key_leftshift)];
                if (ctrl and shift and f_num < tty_device_count) {
                    current_tty_device = f_num;
                    const new_current_dev = tty_devices[current_tty_device];
                    const virt_console: *VirtualConsole = @ptrCast(
                        @alignCast(new_current_dev.driver.internal_data),
                    );

                    virt_console.redraw();
                }
            },
            else => {
                const raw_ch = keyToChar(ev) orelse continue;
                const ch = if (shift_enabled)
                    std.ascii.toUpper(raw_ch)
                else
                    raw_ch;

                // TODO: print in bulk
                const chars: [1]u8 = .{ch};
                current_dev.writeToInputBuffer(&chars);
            },
        }
    }
}
