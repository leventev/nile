pub const std = @import("std");
pub const builtin = @import("builtin");
pub const kio = @import("kio.zig");
pub const devicetree = @import("devicetree.zig");
pub const mm = @import("mem/mm.zig");
pub const buddy_allocator = @import("mem/buddy_allocator.zig");
pub const arch = @import("arch/arch.zig");
pub const time = @import("time.zig");
pub const interrupt = @import("interrupt.zig");
pub const config = @import("config.zig");
pub const scheduler = @import("scheduler.zig");
pub const debug = @import("debug.zig");

pub const slab_allocator = @import("mem/slab_allocator.zig");

export var device_tree_pointer: *void = undefined;

const temp_heap_size = 65535;
var temp_heap: [temp_heap_size]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&temp_heap);
const static_mem_allocator = fba.allocator();

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = kio.kernel_log };

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    _ = error_return_trace;

    std.log.err("KERNEL PANIC: {s}", .{msg});
    std.log.err("Stack trace:", .{});
    const first_trace_addr = @returnAddress();
    var it = std.debug.StackIterator.init(first_trace_addr, null);
    while (it.next()) |addr| {
        std.log.err("    0x{x}", .{addr});
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
    std.log.info("Device tree address: 0x{x}", .{@intFromPtr(device_tree_pointer)});
    const dt = devicetree.readDeviceTreeBlob(static_mem_allocator, device_tree_pointer) catch
        @panic("Failed to read device tree blob");

    inline for (config.modules) |mod| {
        if (!mod.enabled or mod.init_type != .always_run) continue;
        mod.module.init(&dt) catch |err| {
            std.log.err("failed to initialize {s}: {s}", .{ mod.name, @errorName(err) });
        };
        std.log.info("Module '{s}'(always run) initialized", .{mod.name});
    }

    const machine = dt.root().getProperty(.model) orelse @panic("Invalid device tree");
    std.log.info("Machine model: {s}", .{machine});

    const frame_regions = mm.getFrameRegions(static_mem_allocator, &dt) catch
        @panic("Failed to get physical memory regions");

    buddy_allocator.init(frame_regions);
    slab_allocator.init();

    static_mem_allocator.free(frame_regions);

    // find interrupt controllers first
    devicetree.initDriversFromDeviceTreeEarly(&dt);
    devicetree.initDriversFromDeviceTree(&dt);

    scheduler.init();
    _ = scheduler.newKernelThread(thread2) catch unreachable;
    _ = scheduler.newKernelThread(thread3) catch unreachable;

    time.init(&dt) catch @panic("Failed to initialize timer");

    arch.enableInterrupts();

    while (true) {
        std.log.info("thread 1", .{});

        asm volatile ("wfi");
    }
}

fn thread2() void {
    while (true) {
        std.log.info("thread 2", .{});
    }
}

fn thread3() void {
    while (true) {
        std.log.info("thread 3", .{});
    }
}
