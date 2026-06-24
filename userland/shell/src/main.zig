const std = @import("std");
const sys = @import("sys");

export fn _start() void {
    const fd_res = sys.sysOpenat(-1, "/test_dir/a/test_file", 0, 0);
    if (fd_res >= 0) {
        const fd: u32 = @intCast(fd_res);

        var buff: [256]u8 = undefined;
        _ = sys.sysRead(fd, &buff);
        _ = sys.sysRead(42, &buff);
    }
    sys.sysExit(123);
}
