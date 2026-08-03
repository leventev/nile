const std = @import("std");
const sys = @import("sys");

fn exit(exit_code: isize) noreturn {
    sys.exit(exit_code);
    while (true) {}
}

const prompt = "$ ";

var stdout_fd: u32 = undefined;

const Command = struct {
    name: []const u8,
    callback: *const fn (args: []const u8) void,
};

fn echo(args: []const u8) void {
    _ = sys.write(stdout_fd, args) catch {};
}

fn changeDirectory(args: []const u8) void {
    _ = args;
}

const commands = [_]Command{
    .{ .name = "echo", .callback = echo },
    .{ .name = "cd", .callback = changeDirectory },
};

fn processLine(line: []const u8) void {
    const command_end_idx = std.mem.findScalar(u8, line, ' ') orelse line.len;
    const called_command_name = line[0..command_end_idx];
    const args_start_idx = @min(line.len, command_end_idx + 1);
    const args_str = line[args_start_idx..line.len];

    for (commands) |command| {
        if (!std.mem.eql(u8, called_command_name, command.name)) continue;

        command.callback(args_str);
        return;
    }

    var buff: [256]u8 = undefined;
    const error_message = std.fmt.bufPrint(&buff, "error: {s}: command not found", .{called_command_name}) catch
        while (true) {};
    _ = sys.write(stdout_fd, error_message) catch {};
}

export fn _start() void {
    stdout_fd = sys.openat(-1, "/dev/tty0", 0, 0) catch exit(-1);

    const quit = false;

    var line_buff: [512]u8 = undefined;
    var line_buff_written: usize = 0;

    var new_line = true;

    while (!quit) {
        if (new_line) {
            _ = sys.write(stdout_fd, prompt) catch exit(-1);
            new_line = false;
        }

        var buff: [256]u8 = undefined;
        const bytes_read = sys.read(stdout_fd, &buff) catch exit(-1);

        for (0..bytes_read) |i| {
            const ch = buff[i];
            if (ch == '\n') {
                processLine(line_buff[0..line_buff_written]);
                line_buff_written = 0;
                new_line = true;
                _ = sys.write(stdout_fd, "\n") catch exit(-1);
            } else {
                line_buff[line_buff_written] = ch;
                line_buff_written += 1;
            }
        }
    }

    exit(0);
}
