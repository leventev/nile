const std = @import("std");
const sys = @import("sys");

export fn _start() void {
    const fd = sys.sysOpenat(-1, "/test_dir/a", 0, 0);
    _ = fd;
    sys.sysExit(123);
}
