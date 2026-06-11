//! https://docs.oasis-open.org/virtio/virtio/v1.4/virtio-v1.4.html
const std = @import("std");
const Module = @import("../Module.zig");
const pcie = @import("bus/pcie.zig");
const device = @import("../device.zig");
const mm = @import("../mem/mm.zig");
const buddy_allocator = @import("../mem/buddy_allocator.zig");
const arch = @import("../arch/arch.zig");

/// Describes a VIRTIO capability.
/// Linked list whose head is contained in the PCI general header.
const VirtioPCICapability = extern struct {
    /// Generic PCI capability struct.
    generic_pci: pcie.PCICapability,

    /// Identifies the kind of virtio configuration structure.
    configuration_type: ConfigurationType,

    /// Which base address register contains the structure's address.
    bar: u8,

    /// Used by some device types to uniquely identify multiple capabilities of the same type.
    id: u8,

    reserved: u16,

    /// Offset of the structure within the BAR.
    offset: u32,

    /// Size of the structure in bytes.
    size: u32,

    const ConfigurationType = enum(u8) {
        common = 1,
        notify = 2,
        isr = 3,
        device = 4,
        pci = 5,
        shared_memory = 8,
        vendor = 9,
    };
};

/// Notification capability structure. It immediately follows the PCI capability header.
const VirtioPCINotification = extern struct {
    pci_capability: VirtioPCICapability,
    notification_offset_multiplier: u32,
};

/// Common configuration structure.
const VirtioPCICommon = extern struct {
    /// The driver uses this to select the feature bits device_feature shows.
    /// 0x0 selects feature bits 0 to 31, 0x1 selects feature bits 32 to 63, and so on.
    device_feature_select: u32,

    /// The device reports which feature bits it is offering.
    /// The driver uses device_feature_select to select the feature bits reported.
    device_feature: u32,

    /// The driver uses this to select the feature bits driver_feature shows.
    /// 0x0 selects feature bits 0 to 31, 0x1 selects feature bits 32 to 63, and so on.
    driver_feature_select: u32,

    /// The driver uses this to select which feature bits it is
    /// accepting that are offered by the device.
    /// The driver uses device_feature_select to select the feature bits are selected.
    driver_feature: u32,

    /// Set by the driver for configuration change notifications.
    config_msix_vector: u16,

    /// The maximum number of virtqueues supported by the device.
    num_queues: u16,

    /// Status of the device.
    device_status: Status,

    /// The device changes this every time the configuration noticeably changes.
    config_generation: u8,

    /// The driver uses this to select which virtqueue the following fields refer to.
    queue_select: u16,

    /// The size of the selected virtqueue.
    /// On reset it is set to the maximum queue size supported.
    /// A queue size of 0 means the queue is unavabile.
    queue_size: u16,

    /// Set by the driver for virtqueue notifications.
    queue_msix_vector: u16,

    /// Whether the queue is enabled. 1 is enabled, 0 is disabled.
    queue_enable: u16,

    /// Offset in notification_offset_multiplier units
    /// from the start of the Notification structure.
    queue_notify_off: u16,

    /// Physical address of Descriptor Area.
    descriptor_queue: u64,

    /// Physical address of Driver Area.
    driver_queue: u64,

    /// Physical address of Device Area.
    device_queue: u64,

    /// TODO: notification configuration
    queue_notif_config_data: u16,

    /// The driver uses this to reset the queue.
    queue_reset: u16,

    /// TODO: administration virtqueue
    admin_queue_index: u16,
    admin_queue_num: u16,

    const Status = packed struct(u8) {
        acknowledge: bool,
        driver: bool,
        driver_ok: bool,
        features_ok: bool,
        suspended: bool,
        reserved: u1 = 0,
        deivce_needs_reset: bool,
        failed: bool,

        /// Write this to reset.
        const reset: Status = @bitCast(@as(u8, 0));
    };
};

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

const Capabilities = struct {
    common: *VirtioPCICommon,
    notification: *const VirtioPCINotification,
    notification_base_addr: mm.VirtualAddress,
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

    const cfg_space = pcie.ConfigurationSpace.fromAddress(pci_dev.address);
    const header = cfg_space.generalHeader();

    var caps: Capabilities = undefined;
    // TODO: check whether we found it

    var cap_it = pcie.PCICapability.iterator(cfg_space, header.capabilities_pointer);
    while (cap_it.next()) |capability| {
        if (capability.vendor_id != .vendor_specific) continue;

        const virtio_cap: *VirtioPCICapability = @ptrCast(@alignCast(capability));

        std.log.debug("{any}", .{virtio_cap});

        switch (virtio_cap.configuration_type) {
            .common => {
                // TODO: support 32 bit arches
                const bar32 = header.bars[virtio_cap.bar];
                const bar32_addr = bar32 & ~@as(u64, 0b1111);

                const bar_addr = if (bar32 & pcie.bar_type_mask == pcie.bar_type32)
                    bar32_addr
                else if (bar32 & pcie.bar_type_mask == pcie.bar_type64)
                    std.math.shl(u64, header.bars[virtio_cap.bar + 1], 32) + bar32_addr
                else
                    @panic("Invalid BAR type");

                const struct_addr_phys = mm.PhysicalAddress.fromInt(bar_addr + virtio_cap.offset);
                const struct_addr_virt = mm.physicalToVirtualAddress(struct_addr_phys);
                caps.common = @ptrFromInt(struct_addr_virt.asInt());
            },
            .notify => {
                caps.notification = @ptrCast(virtio_cap);

                const bar32 = header.bars[virtio_cap.bar];
                const bar32_addr = bar32 & ~@as(u64, 0b1111);

                const bar_addr = if (bar32 & pcie.bar_type_mask == pcie.bar_type32)
                    bar32_addr
                else if (bar32 & pcie.bar_type_mask == pcie.bar_type64)
                    std.math.shl(u64, header.bars[virtio_cap.bar + 1], 32) + bar32_addr
                else
                    @panic("Invalid BAR type");

                const phys = mm.PhysicalAddress.fromInt(bar_addr + virtio_cap.offset);
                caps.notification_base_addr = mm.physicalToVirtualAddress(phys);
            },
            else => {},
        }
    }

    caps.common.device_status = .reset;
    caps.common.device_status.acknowledge = true;
    caps.common.device_status.driver = true;
    caps.common.device_status.features_ok = true;

    // TODO: negotiate features
    caps.common.device_feature_select = 0;
    caps.common.device_feature = 0;

    std.debug.assert(caps.common.device_status.features_ok);

    const control_queue_id = 0;
    const cursor_queue_id = 1;

    var virt_queue_control = VirtQueue.setup(
        caps.common,
        control_queue_id,
        null,
    ) catch @panic("TODO");

    const virt_queue_cursor = VirtQueue.setup(
        caps.common,
        cursor_queue_id,
        null,
    ) catch @panic("TODO");

    _ = virt_queue_cursor;

    caps.common.device_status.driver_ok = true;

    // TODO: zero descriptor table, available ring and used ring

    // TODO:
    const tmp_phys = buddy_allocator.allocBlock(0) catch unreachable;
    const tmp_virt = mm.physicalToVirtualAddress(tmp_phys);
    const buffer_addr = tmp_virt.asInt();

    const display_rect = getDisplayInfo(
        &virt_queue_control,
        &caps,
        buffer_addr,
    ) orelse @panic("Failed to get display info");

    std.log.debug("display: {}x{}", .{ display_rect.width, display_rect.height });

    const resource_id = 1;
    // TODO:
    const scanout_id = 0;

    const resource_ok = createResource2D(
        &virt_queue_control,
        &caps,
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
        &caps,
        buffer_addr,
        resource_id,
        framebuffer_phys.asInt(),
        framebuffer_size,
    );

    if (!attach_ok) @panic("Failed to attach resource backing");

    const set_scanout_ok = setResourceScanout(
        &virt_queue_control,
        &caps,
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
        &caps,
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
        &caps,
        buffer_addr,
        resource_id,
        display_rect,
    );

    if (!flush_ok) @panic("Failed to flush resource");
}

fn getDisplayInfo(
    control_queue: *VirtQueue,
    caps: *Capabilities,
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

    control_queue.queueChain(caps, 0);

    if (response.header.header_type != .response_ok_display_info)
        return null;

    for (response.display) |display| {
        if (display.enabled != 0) return display.rectangle;
    }

    return null;
}

fn createResource2D(
    control_queue: *VirtQueue,
    caps: *Capabilities,
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

    control_queue.queueChain(caps, 0);

    return response.header_type == .response_ok_nodata;
}

fn attachResourceBacking(
    control_queue: *VirtQueue,
    caps: *Capabilities,
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

    control_queue.queueChain(caps, 0);

    return response.header_type == .response_ok_nodata;
}

fn setResourceScanout(
    control_queue: *VirtQueue,
    caps: *Capabilities,
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

    control_queue.queueChain(caps, 0);

    return response.header_type == .response_ok_nodata;
}

fn transferToHost2D(
    control_queue: *VirtQueue,
    caps: *Capabilities,
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

    control_queue.queueChain(caps, 0);

    return response.header_type == .response_ok_nodata;
}

fn flushResource(
    control_queue: *VirtQueue,
    caps: *Capabilities,
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

    control_queue.queueChain(caps, 0);

    return response.header_type == .response_ok_nodata;
}

/// Note that while the encapsulated structures are defined by the virtio standard,
/// this struct is not. It only exists for easier access to the virtqueue fields,
/// to avoid having to do pointer arithmetic every time we wanted to access them.
const VirtQueue = struct {
    queue_id: u16,
    queue_size: u16,
    descriptor_table: []Descriptor,
    available_ring_header: *AvailableRingHeader,
    available_ring: []u16,
    used_ring_header: *UsedRingHeader,
    used_ring: []UsedElement,

    fn queueChain(self: *VirtQueue, caps: *Capabilities, chain_descriptor_id: u16) void {
        std.debug.assert(chain_descriptor_id < self.queue_size);

        self.available_ring[self.available_ring_header.idx % self.queue_size] = chain_descriptor_id;
        self.available_ring_header.idx +%= 1;

        caps.common.queue_select = self.queue_id;
        const notify_off = caps.common.queue_notify_off;
        const multiplier = caps.notification.notification_offset_multiplier;

        const notif_addr = caps.notification_base_addr.add(multiplier * notify_off);
        const notify_ptr: *u16 = notif_addr.asPtr(*u16);
        notify_ptr.* = 0;

        while (self.used_ring_header.idx != self.available_ring_header.idx) {}
    }

    fn writeNextDescriptor(
        self: *VirtQueue,
        descriptor_id: u16,
        ptr: *anyopaque,
        len: u32,
        next_id: ?u16,
        write_only: bool,
    ) void {
        std.debug.assert(descriptor_id < self.queue_size);

        const phys = mm.virtualToPhysicalAddress(.fromInt(@intFromPtr(ptr)));

        self.descriptor_table[descriptor_id].address = phys.asInt();
        self.descriptor_table[descriptor_id].len = len;
        self.descriptor_table[descriptor_id].next = next_id orelse 0;
        self.descriptor_table[descriptor_id].flags = .{
            .has_next = next_id != null,
            .write_only = write_only,
            .indirect = false,
            .reserved = 0,
        };
    }

    // TODO: maybe pass flags
    fn setup(
        common_cap: *VirtioPCICommon,
        queue_id: u16,
        override_queue_size: ?u16,
    ) !VirtQueue {
        common_cap.queue_select = queue_id;
        var queue_size = common_cap.queue_size;
        std.debug.assert(queue_size != 0);

        if (override_queue_size) |override| {
            if (queue_size < override) @panic("TODO");

            common_cap.queue_size = override;
            queue_size = override;
        }

        const avail_ring_size = @as(usize, queue_size) * @sizeOf(u16);
        const used_ring_size = @as(usize, queue_size) * @sizeOf(UsedElement);
        const desc_tbl_size = @as(usize, queue_size) * @sizeOf(Descriptor);

        var required_size = desc_tbl_size;

        // the used ring must be aligned to Queue Align (which is generally 4096 bytes)
        // so we pad the available ring
        const avail_ring_unpadded_size = @sizeOf(AvailableRingHeader) + avail_ring_size;
        required_size += avail_ring_unpadded_size;
        required_size = std.mem.alignForward(usize, required_size, arch.page_size);
        const avail_ring_total_size = required_size - desc_tbl_size;

        const used_ring_total_size = @sizeOf(UsedRingHeader) + used_ring_size;
        required_size += used_ring_total_size;

        const order = buddy_allocator.blockOrderFromSize(required_size);
        const mem_phys = try buddy_allocator.allocBlock(order);
        var mem_virt = mm.physicalToVirtualAddress(mem_phys);

        const desc_tbl = mem_virt.asPtr([*]Descriptor)[0..queue_size];
        mem_virt = mem_virt.add(desc_tbl_size);

        const avail_ring_header = mem_virt.asPtr(*AvailableRingHeader);
        mem_virt = mem_virt.add(@sizeOf(AvailableRingHeader));
        const avail_ring = mem_virt.asPtr([*]u16)[0..queue_size];
        mem_virt = mem_virt.add(avail_ring_total_size - @sizeOf(AvailableRingHeader));

        const used_ring_header = mem_virt.asPtr(*UsedRingHeader);
        mem_virt = mem_virt.add(@sizeOf(UsedRingHeader));
        const used_ring = mem_virt.asPtr([*]UsedElement)[0..queue_size];

        std.debug.assert(@intFromPtr(desc_tbl.ptr) % arch.page_size == 0);
        std.debug.assert(@intFromPtr(used_ring_header) % arch.page_size == 0);

        avail_ring_header.idx = 0;
        avail_ring_header.flags = .{ .no_interrupt = true, .reserved = 0 };
        used_ring_header.idx = 0;
        used_ring_header.flags = .{ .no_notify = false, .reserved = 0 };

        common_cap.descriptor_queue = mm.virtualToPhysicalAddress(
            .fromInt(@intFromPtr(desc_tbl.ptr)),
        ).asInt();
        common_cap.driver_queue = mm.virtualToPhysicalAddress(
            .fromInt(@intFromPtr(avail_ring_header)),
        ).asInt();
        common_cap.device_queue = mm.virtualToPhysicalAddress(
            .fromInt(@intFromPtr(used_ring_header)),
        ).asInt();

        common_cap.queue_enable = 1;

        return .{
            .queue_id = queue_id,
            .queue_size = queue_size,
            .descriptor_table = desc_tbl,
            .available_ring_header = avail_ring_header,
            .available_ring = avail_ring,
            .used_ring_header = used_ring_header,
            .used_ring = used_ring,
        };
    }

    const Descriptor = extern struct {
        address: u64,

        len: u32,

        flags: Flags,

        next: u16,

        const Flags = packed struct(u16) {
            has_next: bool,
            write_only: bool,
            indirect: bool,

            reserved: u13 = 0,
        };
    };

    const AvailableRingHeader = extern struct {
        flags: Flags,

        idx: u16,

        const Flags = packed struct(u16) {
            no_interrupt: bool,

            reserved: u15 = 0,
        };
    };

    const UsedRingHeader = extern struct {
        flags: Flags,

        idx: u16,

        const Flags = packed struct(u16) {
            no_notify: bool,

            reserved: u15 = 0,
        };
    };

    const UsedElement = extern struct {
        idx: u32,
        len: u32,
    };
};

fn blockOrderFromSize(size: u64) usize {
    std.debug.assert(size >= 4096);

    var s = size;
    var blocks: usize = 1;
    while (s > 4096) {
        s = std.math.shr(u64, s, 1);
        blocks += 1;
    }
    return blocks;
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
