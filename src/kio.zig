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

const kernel_writer_vtable = std.Io.Writer.VTable{
    .drain = drain,
};
pub var kernel_writer = std.Io.Writer{
    .vtable = &kernel_writer_vtable,
    .buffer = &.{},
};

pub const kio_term = std.Io.Terminal{
    .writer = &kernel_writer,
    .mode = .escape_codes,
};

pub fn addBackend(backend: IOBackend) !void {
    if (backend_count == max_backends) return error.TooManyBackends;
    backends[backend_count] = backend;
    backend_count += 1;
    std.log.info("New kernel IO backend added: {s} with priority: {}", .{ backend.name, backend.priority });
}

// TODO: removeBackend

fn logLevelColor(level: std.log.Level) std.Io.Terminal.Color {
    return switch (level) {
        .info => .blue,
        .debug => .magenta,
        .warn => .yellow,
        .err => .red,
    };
}

fn printLogPreamble(comptime scope: @EnumLiteral(), comptime level: std.log.Level) !void {
    const ns = time.nanoseconds() orelse 0;
    const sec = ns / time.ns_per_second;
    const rem = ns % time.ns_per_second;
    const qs = rem / (10 * time.ns_per_microseconds);

    try kernel_writer.print("{}.{:0>5} ", .{ sec, qs });

    try kio_term.setColor(.bold);
    try kio_term.setColor(logLevelColor(level));
    _ = try kernel_writer.write(@tagName(level));
    try kio_term.setColor(.bright_black);
    _ = try kernel_writer.write("(" ++ @tagName(scope) ++ ") ");
    try kio_term.setColor(.reset);
}

fn drain(writer: *std.Io.Writer, buffers: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
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
    if (backend_count == 0) return bytes.len;

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
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    lock.lock();
    printLogPreamble(scope, level) catch unreachable;
    kernel_writer.print(format, args) catch unreachable;
    kernel_writer.writeByte('\n') catch unreachable;
    lock.unlock();
}
