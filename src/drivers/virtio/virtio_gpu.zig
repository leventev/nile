const std = @import("std");
const Module = @import("../../Module.zig");
const pcie = @import("../bus/pcie.zig");
const device = @import("../../device.zig");
const mm = @import("../../mem/mm.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");
const arch = @import("../../arch/arch.zig");
const virtio = @import("virtio.zig");

const VirtioDevice = virtio.VirtioDevice;
const VirtQueue = virtio.VirtQueue;

const ControlHeader = extern struct {
    header_type: Type,
    flags: Flags,
    fence_id: u64,
    context_idx: u32,
    ring_idx: u8,
    padding: [3]u8,

    const Type = enum(u32) {
        command_get_display_info = 0x100,
        command_resource_create_2d,
        command_resource_unref,
        command_set_scanout,
        command_resource_flush,
        command_transfer_to_host_2d,
        command_resource_attach_backing,
        command_resource_detach_backing,
        command_get_capset_info,
        command_get_capset,
        command_get_edid,
        command_resource_assign_uuid,
        command_resource_create_blob,
        command_set_scanout_blob,

        command_update_cursor = 0x300,
        command_move_cursor,

        response_ok_nodata = 0x1100,
        response_ok_display_info,
        response_ok_capset_info,
        response_ok_capset,
        response_ok_edid,
        response_ok_resource_uuid,
        response_ok_map_info,

        response_err_unspec = 0x1200,
        response_err_out_of_memory,
        response_err_invalid_scanout_id,
        response_err_invalid_resource_id,
        response_err_invalid_context_id,
        response_err_invalid_parameter,

        _,
    };

    const Flags = packed struct(u32) {
        fence: bool,
        reserved: u31 = 0,
    };
};

const Rectangle = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const ResponseDisplayInfo = extern struct {
    header: ControlHeader,
    display: [max_scanout]extern struct {
        rectangle: Rectangle,
        enabled: u32,
        flags: u32,
    },

    const max_scanout = 16;
};

const ResourceCreate2D = extern struct {
    header: ControlHeader,
    resource_id: u32,
    pixel_format: PixelFormat,
    width: u32,
    height: u32,

    const PixelFormat = enum(u32) {
        b8g8r8a8 = 1,
        b8g8r8x8 = 2,
        a8r8g8b8 = 3,
        x8r8g8b8 = 4,

        r8g8b8a8 = 67,
        x8b8g8r8 = 68,

        a8b8g8r8 = 121,
        r8g8b8x8 = 134,
    };
};

const ResourceAttachBacking = extern struct {
    header: ControlHeader,
    resource_id: u32,
    memory_entry_count: u32,
};

const ResourceSetScanout = extern struct {
    header: ControlHeader,
    rectangle: Rectangle,
    scanout_id: u32,
    resource_id: u32,
};

const MemoryEntry = extern struct {
    address: u64,
    size: u32,
    padding: u32,
};

const TransferToHost2D = extern struct {
    header: ControlHeader,
    rectangle: Rectangle,
    offset: u64,
    resource_id: u32,
    padding: u32,
};

const ResourceFlush = extern struct {
    header: ControlHeader,
    rectangle: Rectangle,
    resource_id: u32,
    padding: u32,
};

const RGBA = extern struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
};

fn init(dev: *const device.Device) void {
    const pci_dev = pcie.pciDeviceFromDevice(dev);
    std.log.debug("VIRTIO GPU INIT: {x:02}:{x:02}.{}", .{
        pci_dev.address.bus,
        pci_dev.address.device,
        pci_dev.address.function,
    });

    var virt_dev: VirtioDevice = undefined;

    const init_ok = virtio.initializeVirtioDevice(pci_dev, &virt_dev);

    if (!init_ok) @panic("Failed to initialize VirtIO device");

    const control_queue_id = 0;
    const cursor_queue_id = 1;

    var virt_queue_control = VirtQueue.setup(
        virt_dev.common,
        control_queue_id,
        null,
        .{ .no_interrupt = true },
    ) catch @panic("TODO");

    const virt_queue_cursor = VirtQueue.setup(
        virt_dev.common,
        cursor_queue_id,
        null,
        .{ .no_interrupt = true },
    ) catch @panic("TODO");

    _ = virt_queue_cursor;

    virt_dev.common.device_status.driver_ok = true;

    // TODO: zero descriptor table, available ring and used ring

    // TODO:
    const tmp_phys = buddy_allocator.allocBlock(0) catch unreachable;
    const tmp_virt = mm.physicalToVirtualAddress(tmp_phys);
    const buffer_addr = tmp_virt.asInt();

    const display_rect = getDisplayInfo(
        &virt_queue_control,
        &virt_dev,
        buffer_addr,
    ) orelse @panic("Failed to get display info");

    std.log.debug("display: {}x{}", .{ display_rect.width, display_rect.height });

    const resource_id = 1;
    // TODO:
    const scanout_id = 0;

    const resource_ok = createResource2D(
        &virt_queue_control,
        &virt_dev,
        buffer_addr,
        resource_id,
        .r8g8b8a8,
        display_rect.width,
        display_rect.height,
    );

    if (!resource_ok) @panic("Failed to create 2D framebuffer on host");

    const pixel_count = display_rect.width * display_rect.height;
    const framebuffer_size = pixel_count * @sizeOf(u32);

    const fb_block_order = buddy_allocator.blockOrderFromSize(framebuffer_size);
    const framebuffer_phys = buddy_allocator.allocBlock(fb_block_order) catch @panic("TODO");
    const framebuffer_virt = mm.physicalToVirtualAddress(framebuffer_phys);

    const attach_ok = attachResourceBacking(
        &virt_queue_control,
        &virt_dev,
        buffer_addr,
        resource_id,
        framebuffer_phys.asInt(),
        framebuffer_size,
    );

    if (!attach_ok) @panic("Failed to attach resource backing");

    const set_scanout_ok = setResourceScanout(
        &virt_queue_control,
        &virt_dev,
        buffer_addr,
        resource_id,
        scanout_id,
        display_rect,
    );

    if (!set_scanout_ok) @panic("Failed to set resource scanout");

    const framebuffer: []RGBA = framebuffer_virt.asPtr([*]RGBA)[0..pixel_count];
    for (0..display_rect.height) |y| {
        for (0..display_rect.width) |x| {
            framebuffer[y * display_rect.width + x] = .{
                .red = 127,
                .blue = 255,
                .green = 127,
                .alpha = 255,
            };
        }
    }

    const transfer_ok = transferToHost2D(
        &virt_queue_control,
        &virt_dev,
        buffer_addr,
        resource_id,
        0,
        .{
            .x = 0,
            .y = 0,
            .width = display_rect.width,
            .height = display_rect.height,
        },
    );

    if (!transfer_ok) @panic("Failed to transfer to host");

    const flush_ok = flushResource(
        &virt_queue_control,
        &virt_dev,
        buffer_addr,
        resource_id,
        display_rect,
    );

    if (!flush_ok) @panic("Failed to flush resource");
}

fn getDisplayInfo(
    control_queue: *VirtQueue,
    virt_dev: *VirtioDevice,
    buffer_addr: usize,
) ?Rectangle {
    // TODO: check buffer size somehow
    const request: *ControlHeader = @ptrFromInt(buffer_addr);
    const response: *ResponseDisplayInfo = @ptrFromInt(buffer_addr + @sizeOf(ControlHeader));

    request.* = ControlHeader{
        .header_type = .command_get_display_info,
        .fence_id = 0,
        .context_idx = 0,
        .ring_idx = 0,
        .flags = .{ .fence = false },
        .padding = .{ 0, 0, 0 },
    };

    control_queue.writeNextDescriptor(0, request, @sizeOf(ControlHeader), 1, false);
    control_queue.writeNextDescriptor(1, response, @sizeOf(ResponseDisplayInfo), null, true);

    control_queue.queueChain(virt_dev, 0);

    if (response.header.header_type != .response_ok_display_info)
        return null;

    for (response.display) |display| {
        if (display.enabled != 0) return display.rectangle;
    }

    return null;
}

fn createResource2D(
    control_queue: *VirtQueue,
    virt_dev: *VirtioDevice,
    buffer_addr: usize,
    resource_id: u32,
    pixel_format: ResourceCreate2D.PixelFormat,
    width: u32,
    height: u32,
) bool {
    // TODO: check buffer size somehow
    const request: *ResourceCreate2D = @ptrFromInt(buffer_addr);
    const response: *ControlHeader = @ptrFromInt(buffer_addr + @sizeOf(ResourceCreate2D));

    request.* = .{
        .header = .{
            .header_type = .command_resource_create_2d,
            .fence_id = 0,
            .context_idx = 0,
            .ring_idx = 0,
            .flags = .{ .fence = false },
            .padding = .{ 0, 0, 0 },
        },
        .resource_id = resource_id,
        .pixel_format = pixel_format,
        .width = width,
        .height = height,
    };

    control_queue.writeNextDescriptor(0, request, @sizeOf(ResourceCreate2D), 1, false);
    control_queue.writeNextDescriptor(1, response, @sizeOf(ControlHeader), null, true);

    control_queue.queueChain(virt_dev, 0);

    return response.header_type == .response_ok_nodata;
}

fn attachResourceBacking(
    control_queue: *VirtQueue,
    virt_dev: *VirtioDevice,
    buffer_addr: usize,
    resource_id: u32,
    framebuffer_phys_addr: u64,
    framebuffer_size: u32,
) bool {
    // TODO: check buffer size somehow
    const request: *ResourceAttachBacking = @ptrFromInt(buffer_addr);
    const mem_entry: *MemoryEntry = @ptrFromInt(buffer_addr + @sizeOf(ResourceAttachBacking));
    const response_off = buffer_addr + @sizeOf(ResourceAttachBacking) + @sizeOf(MemoryEntry);
    const response: *ControlHeader = @ptrFromInt(response_off);

    request.* = .{
        .header = .{
            .header_type = .command_resource_attach_backing,
            .fence_id = 0,
            .context_idx = 0,
            .ring_idx = 0,
            .flags = .{ .fence = false },
            .padding = .{ 0, 0, 0 },
        },
        .resource_id = resource_id,
        .memory_entry_count = 1,
    };

    mem_entry.address = framebuffer_phys_addr;
    mem_entry.size = framebuffer_size;

    control_queue.writeNextDescriptor(0, request, @sizeOf(ResourceAttachBacking), 1, false);
    control_queue.writeNextDescriptor(1, mem_entry, @sizeOf(MemoryEntry), 2, false);
    control_queue.writeNextDescriptor(2, response, @sizeOf(ControlHeader), null, true);

    control_queue.queueChain(virt_dev, 0);

    return response.header_type == .response_ok_nodata;
}

fn setResourceScanout(
    control_queue: *VirtQueue,
    virt_dev: *VirtioDevice,
    buffer_addr: usize,
    resource_id: u32,
    scanout_id: u32,
    rect: Rectangle,
) bool {
    // TODO: check buffer size somehow
    const request: *ResourceSetScanout = @ptrFromInt(buffer_addr);
    const response: *ControlHeader = @ptrFromInt(buffer_addr + @sizeOf(ResourceSetScanout));

    request.* = .{
        .header = .{
            .header_type = .command_set_scanout,
            .fence_id = 0,
            .context_idx = 0,
            .ring_idx = 0,
            .flags = .{ .fence = false },
            .padding = .{ 0, 0, 0 },
        },
        .resource_id = resource_id,
        .scanout_id = scanout_id,
        .rectangle = rect,
    };

    control_queue.writeNextDescriptor(0, request, @sizeOf(ResourceSetScanout), 1, false);
    control_queue.writeNextDescriptor(1, response, @sizeOf(ControlHeader), null, true);

    control_queue.queueChain(virt_dev, 0);

    return response.header_type == .response_ok_nodata;
}

fn transferToHost2D(
    control_queue: *VirtQueue,
    virt_dev: *VirtioDevice,
    buffer_addr: usize,
    resource_id: u32,
    offset: u64,
    rect: Rectangle,
) bool {
    // TODO: check buffer size somehow
    const request: *TransferToHost2D = @ptrFromInt(buffer_addr);
    const response: *ControlHeader = @ptrFromInt(buffer_addr + @sizeOf(TransferToHost2D));

    request.* = .{
        .header = .{
            .header_type = .command_transfer_to_host_2d,
            .fence_id = 0,
            .context_idx = 0,
            .ring_idx = 0,
            .flags = .{ .fence = false },
            .padding = .{ 0, 0, 0 },
        },
        .offset = offset,
        .resource_id = resource_id,
        .rectangle = rect,
        .padding = 0,
    };

    control_queue.writeNextDescriptor(0, request, @sizeOf(TransferToHost2D), 1, false);
    control_queue.writeNextDescriptor(1, response, @sizeOf(ControlHeader), null, true);

    control_queue.queueChain(virt_dev, 0);

    return response.header_type == .response_ok_nodata;
}

fn flushResource(
    control_queue: *VirtQueue,
    virt_dev: *VirtioDevice,
    buffer_addr: usize,
    resource_id: u32,
    rect: Rectangle,
) bool {
    // TODO: check buffer size somehow
    const request: *ResourceFlush = @ptrFromInt(buffer_addr);
    const response: *ControlHeader = @ptrFromInt(buffer_addr + @sizeOf(ResourceFlush));

    request.* = .{
        .header = .{
            .header_type = .command_resource_flush,
            .fence_id = 0,
            .context_idx = 0,
            .ring_idx = 0,
            .flags = .{ .fence = false },
            .padding = .{ 0, 0, 0 },
        },
        .resource_id = resource_id,
        .rectangle = rect,
        .padding = 0,
    };

    control_queue.writeNextDescriptor(0, request, @sizeOf(ResourceFlush), 1, false);
    control_queue.writeNextDescriptor(1, response, @sizeOf(ControlHeader), null, true);

    control_queue.queueChain(virt_dev, 0);

    return response.header_type == .response_ok_nodata;
}

const device_ids: []const pcie.PCIDevice.Id = &.{
    .{ .vendor_id = 0x1af4, .device_id = 0x1050 },
};

pub const module: Module = .{
    .name = "virtio-gpu",
    .module_type = .{
        .device_driver = .{
            .bus = .{
                .init = init,
                .bus_type = &pcie.pcie_bus,
                .device_ids = device_ids.ptr,
                .device_id_count = device_ids.len,
            },
        },
    },
};
