const std = @import("std");
const sys = @import("sys");

fn exit(exit_code: isize) noreturn {
    sys.sysExit(exit_code);
    while (true) {}
}

var stdout_fd: u32 = undefined;

export fn _start() void {
    const fd_res = sys.sysOpenat(-1, "/dev/tty0", 0, 0);

    if (fd_res < 0) {
        exit(-1);
    }

    const fd: u32 = @intCast(fd_res);
    stdout_fd = fd;

    _ = sys.sysWrite(stdout_fd, "hello world!");

    exit(0);
}
