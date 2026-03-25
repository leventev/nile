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
pub const processes = @import("processes.zig");
pub const slab_allocator = @import("mem/slab_allocator.zig");

const test_file = @embedFile("test");

export var device_tree_pointer: *void = undefined;

const temp_heap_size = 65535;
var temp_heap: [temp_heap_size]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&temp_heap);
const static_mem_allocator = fba.allocator();

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = kio.kernel_log };

const stack_size = 65536;
export var kernel_stack: [stack_size]u8 = undefined;

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

pub fn init(dt_ptr_virt: *void) void {
    // std.log.info("Device tree address: 0x{x}", .{@intFromPtr(dt_ptr_virt)});
    const dt = devicetree.readDeviceTreeBlob(static_mem_allocator, dt_ptr_virt) catch
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

    while (true) {
        std.log.info("HELLO", .{});
    }

    scheduler.init();

    time.init(&dt) catch @panic("Failed to initialize timer");

    arch.enableInterrupts();

    processes.init();
    _ = processes.spawnProcess(null, test_file) catch @panic("TODO");

    while (true) {
        std.log.info("thread 1", .{});

        asm volatile ("wfi");
    }
}
