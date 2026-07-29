const std = @import("std");
const sys = @import("sys");

fn exit(exit_code: isize) noreturn {
    sys.sysExit(exit_code);
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
    const fd_res = sys.sysOpenat(-1, "/dev/tty0", 0, 0);

    if (fd_res < 0) {
        exit(-1);
    }

    const fd: u32 = @intCast(fd_res);
    stdout_fd = fd;

    const root_dir_fd_res = sys.sysOpenat(-1, "/test_dir", 0, 0);
    if (root_dir_fd_res < 0) {
        exit(-1);
    }

    const root_dir_fd: u32 = @intCast(root_dir_fd_res);

    var buffer: [512]u8 align(@alignOf(DirectoryEntry)) = undefined;
    const read_res = sys.sysRead(root_dir_fd, &buffer);
    if (read_res < 0) {
        exit(-1);
    }

    var byte_counter: usize = 0;
    while (byte_counter < read_res) {
        const struct_ptr: *DirectoryEntry = @ptrCast(@alignCast(&buffer[byte_counter]));
        const name_ptr: [*]const u8 = @ptrCast(&buffer[byte_counter + @sizeOf(DirectoryEntry)]);
        const name = name_ptr[0..struct_ptr.name_size];

        _ = sys.sysWrite(stdout_fd, name);
        _ = sys.sysWrite(stdout_fd, " ");

        const total_len = struct_ptr.name_size + @sizeOf(DirectoryEntry);
        const padded_len = std.mem.alignForward(
            usize,
            total_len,
            @sizeOf(DirectoryEntry),
        );
        byte_counter += padded_len;
    }
    _ = sys.sysWrite(stdout_fd, "\n");

    exit(0);
}
