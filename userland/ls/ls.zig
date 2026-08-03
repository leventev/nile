const std = @import("std");
const sys = @import("sys");

fn exit(exit_code: isize) noreturn {
    sys.exit(exit_code);
    while (true) {}
}

var stdout_fd: u32 = undefined;

pub const DirectoryEntry = extern struct {
    name_size: u32,
    type: u32,
    inode: u64,

    // name ...
};

export fn _start() void {
    stdout_fd = sys.openat(-1, "/dev/tty0", 0, 0) catch exit(-1);

    const root_dir_fd = sys.openat(-1, "/test_dir", 0, 0) catch exit(-1);

    var buffer: [512]u8 align(@alignOf(DirectoryEntry)) = undefined;
    const bytes_read = sys.read(root_dir_fd, &buffer) catch exit(-1);

    var byte_counter: usize = 0;
    while (byte_counter < bytes_read) {
        const struct_ptr: *DirectoryEntry = @ptrCast(@alignCast(&buffer[byte_counter]));
        const name_ptr: [*]const u8 = @ptrCast(&buffer[byte_counter + @sizeOf(DirectoryEntry)]);
        const name = name_ptr[0..struct_ptr.name_size];

        _ = sys.write(stdout_fd, name) catch exit(-1);
        _ = sys.write(stdout_fd, " ") catch exit(-1);

        const total_len = struct_ptr.name_size + @sizeOf(DirectoryEntry);
        const padded_len = std.mem.alignForward(
            usize,
            total_len,
            @sizeOf(DirectoryEntry),
        );
        byte_counter += padded_len;
    }
    _ = sys.write(stdout_fd, "\n") catch exit(-1);

    exit(0);
}
