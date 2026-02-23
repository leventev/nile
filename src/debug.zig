const std = @import("std");

var dwarf: std.debug.Dwarf = .{
    .is_macho = false,
    .endian = .little,
};

const Dwarf = std.debug.Dwarf;

// TODO: fix this when zig stdlib gets fixed :)
// does not work due to https://github.com/ziglang/zig/issues/18604
pub fn init(gpa: std.mem.Allocator) void {
    const sections = [_][]const u8{
        "debug_info",
        "debug_abbrev",
        // "debug_str",
        // "debug_ranges",
        // "debug_line",
        // "debug_frame",
    };

    inline for (sections) |s| {
        const start_sym: *u64 = @extern(*u64, .{ .name = "__" ++ s ++ "_start" });
        const end_sym: *u64 = @extern(*u64, .{ .name = "__" ++ s ++ "_end" });
        const start_addr: u64 = @intFromPtr(start_sym);
        const end_addr: u64 = @intFromPtr(end_sym);

        std.log.debug("name: {s} start: 0x{x} end: 0x{x}", .{ s, start_addr, end_addr });

        const start_ptr: [*]u8 = @ptrFromInt(start_addr);
        const size = end_addr - start_addr;
        const data = blk: {
            break :blk start_ptr[0..size];
        };

        dwarf.sections[@intFromEnum(@field(Dwarf.Section.Id, s))] = Dwarf.Section{
            .data = data,
            .owned = false,
        };
    }

    dwarf.open(gpa) catch |err| @panic(@errorName(err));
}
