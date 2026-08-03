const std = @import("std");
const sys = @import("sys");

pub fn main() void {
    const root_dir_fd = sys.openat(-1, "/test_dir", 0, 0) catch sys.exit(-1);

    var buffer: [512]u8 align(@alignOf(sys.DirectoryEntry)) = undefined;
    const bytes_read = sys.read(root_dir_fd, &buffer) catch sys.exit(-1);

    var byte_counter: usize = 0;
    while (byte_counter < bytes_read) {
        const struct_ptr: *sys.DirectoryEntry = @ptrCast(@alignCast(&buffer[byte_counter]));
        const name_ptr: [*]const u8 = @ptrCast(
            &buffer[byte_counter + @sizeOf(sys.DirectoryEntry)],
        );
        const name = name_ptr[0..struct_ptr.name_size];

        _ = sys.write(sys.stdout_fd, name) catch sys.exit(-1);
        _ = sys.write(sys.stdout_fd, " ") catch sys.exit(-1);

        const total_len = struct_ptr.name_size + @sizeOf(sys.DirectoryEntry);
        const padded_len = std.mem.alignForward(usize, total_len, @sizeOf(sys.DirectoryEntry));
        byte_counter += padded_len;
    }
    _ = sys.write(sys.stdout_fd, "\n") catch sys.exit(-1);
}
