const std = @import("std");
const sys = @import("sys");
const user = @import("user");

comptime {
    _ = user;
}

pub export fn _start() void {
    sys.stdout_fd = sys.openat(null, "/dev/tty0", 0, 0) catch sys.exit(-1);
    user.main();
    sys.exit(0);
}
