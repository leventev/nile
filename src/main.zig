pub const std = @import("std");
pub const builtin = @import("builtin");
pub const kio = @import("kio.zig");
pub const devicetree = @import("devicetree.zig");
pub const mm = @import("mem/mm.zig");
pub const phys = @import("mem/phys.zig");
pub const arch = @import("arch/arch.zig");
pub const time = @import("time.zig");
pub const interrupt = @import("interrupt.zig");
pub const config = @import("config.zig");

export var device_tree_pointer: *void = undefined;

const temp_heap_size = 65535;
var temp_heap: [temp_heap_size]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&temp_heap);
const static_mem_allocator = fba.allocator();

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    _ = error_return_trace;

    kio.err("KERNEL PANIC: {s}", .{msg});
    kio.err("Stack trace:", .{});
    const first_trace_addr = @returnAddress();
    var it = std.debug.StackIterator.init(first_trace_addr, null);
    while (it.next()) |addr| {
        kio.err("    0x{x}", .{addr});
    }
    while (true) {}
}

export fn kmain() linksection(".init") void {
    // at this point virtual memory is still disabled
    arch.init();
    // virtual memory has been enabled
    init();
}

fn init() void {
    kio.info("Device tree address: 0x{x}", .{@intFromPtr(device_tree_pointer)});
    const dt = devicetree.readDeviceTreeBlob(static_mem_allocator, device_tree_pointer) catch
        @panic("Failed to read device tree blob");

    inline for (config.modules) |mod| {
        if (!mod.enabled or mod.init_type != .always_run) continue;
        mod.module.init(&dt) catch |err| {
            kio.err("failed to initialize {s}: {s}", .{ mod.name, @errorName(err) });
        };
        kio.info("Module '{s}'(always run) initialized", .{mod.name});
    }

    const machine = dt.root().getProperty(.model) orelse @panic("Invalid device tree");
    kio.info("Machine model: {s}", .{machine});

    const frame_regions = mm.getFrameRegions(static_mem_allocator, &dt) catch
        @panic("Failed to get physical memory regions");

    phys.init(static_mem_allocator, frame_regions) catch
        @panic("Failed to initialize physical frame allocator");

    static_mem_allocator.free(frame_regions);

    //arch.initInterrupts();

    // find interrupt controllers first
    devicetree.initDriversFromDeviceTreeEarly(&dt);
    devicetree.initDriversFromDeviceTree(&dt);

    time.init(&dt) catch @panic("Failed to initialize timer");

    arch.enableInterrupts();

    while (true) {
        asm volatile ("wfi");
    }
}
