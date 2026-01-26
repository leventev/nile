const std = @import("std");
pub const arch = @import("arch/arch.zig");
pub const buddy_allocator = @import("mem/phys/buddy_allocator.zig");

test {
    std.testing.refAllDecls(@This());
}
