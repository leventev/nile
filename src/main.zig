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
pub const Thread = @import("Thread.zig");
pub const cpio = @import("cpio.zig");
pub const ramfs = @import("drivers/ramfs.zig");
pub const fs = @import("fs.zig");

const test_binary_file = @embedFile("test");
const test_archive = @embedFile("root.cpio");

export var device_tree_pointer: *void = undefined;

const temp_heap_size = 65535;
var temp_heap: [temp_heap_size]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&temp_heap);
const static_mem_allocator = fba.allocator();

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = kio.kernel_log,
    .page_size_min = 4096,
};

pub const std_options_debug_io: std.Io = std.Io.failing;

export const init_kernel_stack_size: usize = 65536;
export var init_kernel_stack: [init_kernel_stack_size]u8 = undefined;

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    _ = error_return_trace;

    if (msg.len > 0) {
        std.log.err("KERNEL PANIC: {s}", .{msg});
    } else {
        std.log.err("KERNEL PANIC", .{});
    }

    std.log.err("Stack trace:", .{});
    const max_stacktrace_depth = 64;
    var address_buffer: [max_stacktrace_depth]usize = undefined;
    const stack_trace = std.debug.captureCurrentStackTrace(
        .{ .first_address = @returnAddress() },
        &address_buffer,
    );
    for (stack_trace.return_addresses) |addr| {
        std.log.err("    0x{x}", .{addr});
    }
    while (true) {}
}

pub fn init(root_page_table: arch.PageTable, dt_ptr_virt: *void) noreturn {
    std.log.info("Device tree address: 0x{x}", .{@intFromPtr(dt_ptr_virt)});
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

    scheduler.init();

    time.init(&dt) catch @panic("Failed to initialize timer");

    fs.init();

    var ram_file_system: fs.FileSystem = .{
        .name = "ramfs",
        .flags = .{},
        .mount_init = ramfs.init,
    };

    fs.registerFileSystem(&ram_file_system) catch @panic("Failed to register ramfs");
    fs.dumpRegisteredFilesystems();

    var mount_table: fs.MountTable = .{
        .mount_count = 0,
        .mounts = .{},
        .lock = .{},
    };
    fs.mountFileSystem(&mount_table, "/", "ramfs", null) catch @panic("Failed to mount /");
    mount_table.dump();

    // TODO
    // var initramfs: ramfs.RamFs = undefined;
    // initramfs.init() catch unreachable;
    //
    // cpio.readArchive(test_archive, &initramfs) catch |err| {
    //     std.log.err("Failed to read CPIO archive: {s}", .{@errorName(err)});
    //     @panic("");
    // };
    //
    // initramfs.dumpTree();

    const idle_process_thread = processes.init();
    _ = processes.spawnInitProcess(root_page_table, null, test_binary_file) catch @panic("TODO");
    // TODO: this could probably be done in a nicer way
    arch.scheduleNextThread(idle_process_thread);

    // interrupts must be enabled only after we spawned PID 1
    arch.enableInterrupts();

    while (true) {
        asm volatile ("wfi");
    }
}
