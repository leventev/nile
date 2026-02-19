const std = @import("std");

const sbi = @import("arch/riscv64/sbi.zig");
const time = @import("time.zig");
const arch = @import("arch/arch.zig");

pub const IOBackend = struct {
    name: []const u8,
    writeBytes: *const fn (bytes: []const u8) ?usize,
    priority: usize,
};

const max_backends = 8;

var backends: [max_backends]IOBackend = undefined;
var backend_count: usize = 0;

const kernel_writer_vtable = std.io.Writer.VTable{
    .drain = drain,
};
pub var kernel_writer = std.io.Writer{
    .vtable = &kernel_writer_vtable,
    .buffer = &.{},
};

const kio_cfg: std.io.tty.Config = .escape_codes;

pub fn addBackend(backend: IOBackend) !void {
    // TODO: locking
    if (backend_count == max_backends) return error.TooManyBackends;
    backends[backend_count] = backend;
    backend_count += 1;
    std.log.info("New kernel IO backend added: {s} with priority: {}", .{ backend.name, backend.priority });
}

// TODO: removeBackend

fn logLevelColor(level: std.log.Level) std.io.tty.Color {
    return switch (level) {
        .info => .blue,
        .debug => .magenta,
        .warn => .yellow,
        .err => .red,
    };
}

fn printLogPreamble(comptime scope: @Type(.enum_literal), comptime level: std.log.Level) !void {
    const ns = time.nanoseconds() orelse 0;
    const sec = ns / time.ns_per_second;
    const rem = ns % time.ns_per_second;
    const qs = rem / (10 * time.ns_per_microseconds);

    try kernel_writer.print("{}.{:0>5} ", .{ sec, qs });

    try kio_cfg.setColor(&kernel_writer, std.io.tty.Color.bold);
    try kio_cfg.setColor(&kernel_writer, logLevelColor(level));
    _ = try kernel_writer.write(@tagName(level));
    try kio_cfg.setColor(&kernel_writer, std.io.tty.Color.bright_black);
    _ = try kernel_writer.write("(" ++ @tagName(scope) ++ ") ");
    try kio_cfg.setColor(&kernel_writer, std.io.tty.Color.reset);
}

fn drain(writer: *std.io.Writer, buffers: []const []const u8, splat: usize) std.io.Writer.Error!usize {
    _ = writer;
    // TODO: implement expected drain behavior
    _ = splat;
    var written: usize = 0;
    for (buffers) |bytes| {
        written += try writeBytes(bytes);
    }

    return written;
}

fn writeBytes(bytes: []const u8) error{}!usize {
    // TODO: locking
    if (backend_count == 0) return 0;

    // TODO: order the list so we don't have to loop each time
    var best = &backends[0];
    for (backends[1..backend_count]) |*backend| {
        if (backend.priority > best.priority)
            best = backend;
    }

    return best.writeBytes(bytes) orelse unreachable;
}

var lock: arch.Lock = .{};

pub fn kernel_log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    lock.lock();
    printLogPreamble(scope, level) catch unreachable;
    kernel_writer.print(format, args) catch unreachable;
    kernel_writer.writeByte('\n') catch unreachable;
    lock.unlock();
}
