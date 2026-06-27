pub const std = @import("std");
pub const builtin = @import("builtin");
pub const kio = @import("kio.zig");
pub const devicetree = @import("dt/devicetree.zig");
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
pub const vfs = @import("vfs.zig");
pub const Module = @import("Module.zig");
pub const device = @import("device.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const pc_font = @import("pc_font.zig");
pub const kernel_gpa = @import("mem/kernel_gpa.zig");
pub const console = @import("console.zig");
pub const DeviceFilesystem = @import("DeviceFilesystem.zig");

const test_binary_file = @embedFile("shell");
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
    arch.disableInterrupts();

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

    const machine = dt.root().getProperty(.model) orelse @panic("Invalid device tree");
    std.log.info("Machine model: {s}", .{machine});

    const frame_regions = mm.getFrameRegions(static_mem_allocator, &dt) catch
        @panic("Failed to get physical memory regions");

    // devicetree.printDeviceTree(&dt, 0, 0);
    buddy_allocator.init(frame_regions);
    slab_allocator.init();

    static_mem_allocator.free(frame_regions);

    var allocator: kernel_gpa.KernelGPA = undefined;
    allocator.init();
    const gpa = allocator.allocator();

    vfs.init();

    vfs.registerFileSystem(&DeviceFilesystem.skeleton);

    const devfs = vfs.createFileSystem(gpa, "devfs") catch unreachable;
    const devfs_internal: *DeviceFilesystem = @ptrCast(@alignCast(devfs.internal_data));

    // find interrupt controllers first
    devicetree.addDevices(&dt) catch @panic("TODO");

    // initialize the thread cache so that drivers can create
    // soft interrupts,
    // or TODO: make the drivers store the
    // Thread structure themselves
    scheduler.init();

    device.matchDeviceTreeDevices(&dt, devfs_internal);

    while (device.matchNonDeviceTreeDevices(devfs_internal)) {}

    device.enableInterrupts(gpa);

    Module.registerFsModules();

    pc_font.init();

    framebuffer.fillRect(0, 100, 300, 500, .{
        .red = 100,
        .green = 200,
        .blue = 50,
        .alpha = 255,
    });

    framebuffer.fillRect(300, 300, 400, 50, .{
        .red = 100,
        .green = 200,
        .blue = 250,
        .alpha = 255,
    });

    framebuffer.flush();

    time.init(&dt) catch @panic("Failed to initialize timer");

    vfs.dumpRegisteredFilesystems();

    var mount_table: vfs.MountTable = .{
        .mount_count = 0,
        .mounts = null,
        .lock = .{},
    };

    const ramfs = vfs.createFileSystem(gpa, "ramfs") catch @panic("Failed to create ramfs");

    vfs.mountFileSystem(&mount_table, "/", ramfs) catch @panic("Failed to mount /");
    vfs.createDirectory(&mount_table, "/dev") catch @panic("Failed to create /dev directory");
    vfs.mountFileSystem(&mount_table, "/dev", devfs) catch @panic("Failed to mount /dev");
    vfs.createDirectory(&mount_table, "/test_dir") catch @panic("Failed to create file");
    vfs.createDirectory(&mount_table, "/test_dir/a") catch @panic("Failed to create file");
    vfs.createDirectory(&mount_table, "/test_dir/b") catch @panic("Failed to create file");
    vfs.createRegularFile(&mount_table, "/test_dir/a/test_file", "burger") catch @panic("Failed to create file");

    console.init(gpa, devfs_internal, &framebuffer.framebuffers[0]) catch @panic("TODO");

    mount_table.dump();
    vfs.dumpTree(&mount_table);

    //
    // // TODO
    // // var initramfs: ramfs.RamFs = undefined;
    // // initramfs.init() catch unreachable;
    // //
    // // cpio.readArchive(test_archive, &initramfs) catch |err| {
    // //     std.log.err("Failed to read CPIO archive: {s}", .{@errorName(err)});
    // //     @panic("");
    // // };
    // //
    // // initramfs.dumpTree();

    const idle_process_thread = processes.init();
    _ = processes.spawnInitProcess(
        root_page_table,
        null,
        test_binary_file,
        &mount_table,
    ) catch @panic("TODO");
    // TODO: this could probably be done in a nicer way
    arch.scheduleNextThread(idle_process_thread);

    // interrupts must be enabled only after we spawned PID 1
    arch.enableInterrupts();

    while (true) {
        asm volatile ("wfi");
    }
}
