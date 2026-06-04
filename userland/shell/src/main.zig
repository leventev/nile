const std = @import("std");
const sys = @import("sys");

export fn _start() void {
    sys.sysExit(123);
}
