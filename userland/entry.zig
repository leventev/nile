const std = @import("std");
const sys = @import("sys");
const user = @import("user");

comptime {
    _ = user;
}

pub export fn _start(arg_ptr: [*]u8, arg_size: usize) void {
    sys.stdout_fd = sys.openat(null, "/dev/tty0", 0, 0) catch sys.exit(-1);
    const buff = arg_ptr[0..arg_size];
    user.main(buff);
    sys.exit(0);
}
