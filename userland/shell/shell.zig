const std = @import("std");
const sys = @import("sys");

fn exit(exit_code: isize) noreturn {
    sys.exit(exit_code);
    while (true) {}
}

const prompt = "$ ";

const Command = struct {
    name: []const u8,
    callback: *const fn (args: []const u8) void,
};

fn echo(args: []const u8) void {
    _ = sys.write(sys.stdout_fd, args) catch {};
}

fn changeDirectory(args: []const u8) void {
    _ = args;
}

fn dosuno(args: []const u8) void {
    _ = args;
    _ = sys.write(sys.stdout_fd, "endre buzi") catch {};
}

const commands = [_]Command{
    .{ .name = "echo", .callback = echo },
    .{ .name = "cd", .callback = changeDirectory },
    .{ .name = "dosuno", .callback = dosuno },
};

fn findExternalProgram(search_path: []const []const u8, program_name: []const u8) ?u32 {
    for (search_path) |directory_path| {
        const dir_fd = sys.openat(null, directory_path, 0, 0) catch continue;

        const buff_size = 4096;
        var buff: [buff_size]u8 align(@sizeOf(sys.core.fs.DirectoryEntryHeader)) = undefined;
        var continue_reading = true;
        while (continue_reading) {
            var dir_iter = sys.readDirectory(dir_fd, &buff) catch return null;
            var entries_read: usize = 0;
            while (dir_iter.next()) |dir_ent| {
                entries_read += 1;
                if (!std.mem.eql(u8, dir_ent.name, program_name)) continue;

                return sys.openat(dir_fd, dir_ent.name, 0, 0) catch null;
            }

            continue_reading = entries_read != 0;
        }
    }

    return null;
}

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

    const search_path = &.{ "/sbin", "/bin" };
    if (findExternalProgram(search_path, called_command_name)) |external_fd| {
        _ = sys.spawn(external_fd, 0) catch {};
        return;
    }

    var buff: [256]u8 = undefined;
    const error_message = std.fmt.bufPrint(
        &buff,
        "error: {s}: command not found",
        .{called_command_name},
    ) catch exit(-1);

    _ = sys.write(sys.stdout_fd, error_message) catch exit(-1);
}

pub fn main() void {
    const quit = false;

    var line_buff: [512]u8 = undefined;
    var line_buff_written: usize = 0;

    var new_line = true;

    while (!quit) {
        if (new_line) {
            _ = sys.write(sys.stdout_fd, prompt) catch exit(-1);
            new_line = false;
        }

        var buff: [256]u8 = undefined;
        const bytes_read = sys.read(sys.stdout_fd, &buff) catch exit(-1);

        for (0..bytes_read) |i| {
            const ch = buff[i];
            if (ch == '\n') {
                processLine(line_buff[0..line_buff_written]);
                line_buff_written = 0;
                new_line = true;
                _ = sys.write(sys.stdout_fd, "\n") catch exit(-1);
            } else {
                line_buff[line_buff_written] = ch;
                line_buff_written += 1;
            }
        }
    }
}
