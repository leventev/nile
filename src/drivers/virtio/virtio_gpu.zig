const std = @import("std");
const Module = @import("../../Module.zig");
const pcie = @import("../bus/pcie.zig");
const device = @import("../../device.zig");
const mm = @import("../../mem/mm.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");
const arch = @import("../../arch/arch.zig");
const virtio = @import("virtio.zig");
const framebuffer = @import("../../framebuffer.zig");

const VirtioDevice = virtio.VirtioDevice;
const VirtQueue = virtio.VirtQueue;

/// Fixed sized header that is at the start of every request and response.
const ControlHeader = extern struct {
    /// Type of this header.
    header_type: Type,

    flags: Flags,

    /// TODO: Fence id.
    fence_id: u64,

    /// Context id. Only relevant in 3D.
    context_idx: u32,

    /// TODO: Ring idx.
    ring_idx: u8,

    padding: [3]u8,

    /// Header types.
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

/// Pixel format used by virtio-gpu
const PixelFormat = enum(u32) {
    bgra = 1,
    bgrx = 2,
    argb = 3,
    xrgb = 4,

    rgba = 67,
    xbgr = 68,

    abgr = 121,
    rgbx = 134,
};

const feature_virgl = 1 << 0;
const feature_edid = 1 << 1;
const feature_resource_uuid = 1 << 2;
const feature_resource_blob = 1 << 3;
const feature_context_init = 1 << 4;
const feature_blob_alignment = 1 << 5;

// TODO: allocate properly + deallocate
var gpu: VirtioGPU = undefined;

const log = std.log.scoped(.virtio_gpu);

fn setupFramebuffer(
    private_data: *anyopaque,
    fb_disp_data: *framebuffer.Framebuffer.Display,
) bool {
    var virtio_gpu: *VirtioGPU = @ptrCast(@alignCast(private_data));

    const display_info_resp = virtio_gpu.getDisplayInfo() orelse @panic("Failed to get display info");
    var display_found = false;

    for (display_info_resp.display, 0..) |display, i| {
        if (display.enabled != 0) {
            virtio_gpu.rectangle = display.rectangle;
            virtio_gpu.scanout_id = @intCast(i);
            display_found = true;
            break;
        }
    }

    if (!display_found) {
        log.warn("No enabled displays", .{});
        return false;
    }

    // arbitrarily chosen
    virtio_gpu.resource_id = 1;

    const resource_ok = virtio_gpu.createResource2D(
        virtio_gpu.resource_id,
        .rgba,
        virtio_gpu.rectangle.width,
        virtio_gpu.rectangle.height,
    );

    if (!resource_ok) {
        log.warn("Failed to create {}x{} 2D resource on host", .{
            virtio_gpu.rectangle.width,
            virtio_gpu.rectangle.height,
        });
        return false;
    }

    const pixel_count = virtio_gpu.rectangle.width * virtio_gpu.rectangle.height;
    const framebuffer_size = pixel_count * @sizeOf(u32);

    const fb_block_order = buddy_allocator.blockOrderFromSize(framebuffer_size);
    const framebuffer_phys = buddy_allocator.allocBlock(fb_block_order) catch @panic("TODO");
    const framebuffer_virt = mm.physicalToVirtualAddress(framebuffer_phys);

    const attach_ok = virtio_gpu.attachResourceBacking(
        virtio_gpu.resource_id,
        framebuffer_phys.asInt(),
        framebuffer_size,
    );

    if (!attach_ok) {
        log.warn("Failed to attach framebuffer to resource {}", .{virtio_gpu.resource_id});
        return false;
    }

    const set_scanout_ok = virtio_gpu.setResourceScanout(
        virtio_gpu.resource_id,
        virtio_gpu.scanout_id,
        virtio_gpu.rectangle,
    );

    if (!set_scanout_ok) {
        log.warn("Failed to set scanout {} to resource {}", .{
            virtio_gpu.scanout_id,
            virtio_gpu.resource_id,
        });
        return false;
    }

    fb_disp_data.format = .rgba;
    fb_disp_data.width = virtio_gpu.rectangle.width;
    fb_disp_data.height = virtio_gpu.rectangle.height;
    fb_disp_data.memory = framebuffer_virt.asPtr(*anyopaque);

    return true;
}

fn flushScreen(private_data: *anyopaque) void {
    var virtio_gpu: *VirtioGPU = @ptrCast(@alignCast(private_data));

    const transfer_ok = virtio_gpu.transferToHost2D(virtio_gpu.resource_id, virtio_gpu.scanout_id, virtio_gpu.rectangle);
    if (!transfer_ok) {
        log.warn("Failed to transfer framebuffer data to the host", .{});
        return;
    }

    const flush_ok = virtio_gpu.flushResource(virtio_gpu.resource_id, virtio_gpu.rectangle);
    if (!flush_ok) {
        log.warn("Failed to flush the resource", .{});
        return;
    }
}

fn init(dev: *device.Device) void {
    const pci_dev = pcie.pciDeviceFromDevice(dev);
    const features = virtio.initializeVirtioDevice(pci_dev, &gpu.virtio_device, 0);

    gpu.negotiated_features = features orelse @panic("Failed to initialize VirtIO device");

    const control_queue_id = 0;
    const cursor_queue_id = 1;

    gpu.control_queue = VirtQueue.setup(
        gpu.virtio_device.common,
        control_queue_id,
        null,
        .{ .no_interrupt = true },
    ) catch @panic("TODO");

    gpu.cursor_queue = VirtQueue.setup(
        gpu.virtio_device.common,
        cursor_queue_id,
        null,
        .{ .no_interrupt = true },
    ) catch @panic("TODO");

    gpu.virtio_device.common.device_status.driver_ok = true;

    const buffer_phys = buddy_allocator.allocBlock(0) catch unreachable;
    gpu.builder.address = mm.physicalToVirtualAddress(buffer_phys);
    gpu.builder.size = arch.page_size;

    _ = framebuffer.addFramebuffer(
        .{
            .setup = setupFramebuffer,
            .flush = flushScreen,
        },
        &gpu,
    );
}

/// Describes a virtio-gpu device.
pub const VirtioGPU = struct {
    /// The underyling virtio-device.
    virtio_device: VirtioDevice,

    /// The control queue where we send requests and repsonses.
    control_queue: VirtQueue,

    /// Cursor queue for fast-tracking cursor commands.
    cursor_queue: VirtQueue,

    /// Features that were negotiated with the device.
    negotiated_features: u128,

    /// Used as a buffer for requests and responses. Allocated by the buddy allocator.
    /// Basically a bump allocator.
    builder: struct {
        /// Virtual address of the buffer.
        address: mm.VirtualAddress,

        /// Size of the buffer.
        size: usize,

        /// Counter used when allocating.
        counter: usize,

        /// Reset counter to 0.
        inline fn start(self: *@This()) void {
            self.counter = 0;
        }

        /// Allocate space for the provided type and return a pointer to it.
        inline fn get(self: *@This(), comptime T: type) *T {
            const ptr: *T = @ptrFromInt(self.address.asInt() + self.counter);
            self.counter += @sizeOf(T);
            std.debug.assert(self.counter < self.size);

            return ptr;
        }
    },

    /// The resource the framebuffer is attached to.
    resource_id: u32,

    /// The display the resource is associated with.
    scanout_id: u32,

    /// The size of the display/scanout.
    rectangle: Rectangle,

    /// Response of the display info command.
    pub const DisplayInfoResponse = extern struct {
        header: ControlHeader,

        /// Array of displays.
        display: [max_scanout]extern struct {
            /// Size of the display.
            rectangle: Rectangle,

            /// Whether the display is enabled.
            enabled: u32,
            flags: u32,
        },

        const max_scanout = 16;
    };

    /// Queries information about the displays.
    /// The return pointer is only valid until the next builder.start() call.
    pub fn getDisplayInfo(self: *VirtioGPU) ?*DisplayInfoResponse {
        self.builder.start();
        const rqst = self.builder.get(ControlHeader);
        const resp = self.builder.get(DisplayInfoResponse);

        rqst.* = .{
            .header_type = .command_get_display_info,
            .fence_id = 0,
            .context_idx = 0,
            .ring_idx = 0,
            .flags = .{ .fence = false },
            .padding = .{ 0, 0, 0 },
        };

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ControlHeader), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(DisplayInfoResponse), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        if (resp.header.header_type != .response_ok_display_info)
            return null;

        return resp;
    }

    /// Get EDID request.
    const GetEDID = extern struct {
        header: ControlHeader,

        /// Selected display.
        scanout: u32,

        padding: u32,
    };

    /// Response to a get EDID command.
    const GetEDIDResponse = extern struct {
        header: ControlHeader,
        size: u32,
        padding: u32,

        /// EDID data defined by VESA.
        edid: [1024]u8,
    };

    /// Queries the EDID information about the provided scanout.
    /// If the EDID feature was not negotiated or the scanout number is invalid null is returned.
    /// Otherise returns the successful response.
    /// The return pointer is only valid until the next builder.start() call.
    pub fn getEDID(self: *VirtioGPU, scanout: u32) ?*GetEDIDResponse {
        if (self.negotiated_features & feature_edid == 0)
            return null;

        self.builder.start();
        const rqst = self.builder.get(GetEDID);
        const resp = self.builder.get(GetEDIDResponse);

        rqst.* = .{
            .header = .{
                .header_type = .command_get_edid,
                .fence_id = 0,
                .context_idx = 0,
                .ring_idx = 0,
                .flags = .{ .fence = false },
                .padding = .{ 0, 0, 0 },
            },
            .scanout = scanout,
            .padding = 0,
        };

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(GetEDID), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(GetEDIDResponse), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        if (resp.header.header_type != .response_ok_edid)
            return null;

        return resp;
    }

    /// 2D resouce create command.
    const ResourceCreate2D = extern struct {
        header: ControlHeader,

        /// Requested resource id.
        resource_id: u32,

        /// Format of the pixel colors.
        pixel_format: PixelFormat,

        width: u32,
        height: u32,
    };

    /// Creates a width * height sized pixel_format resource on the device.
    /// Returns whether the operation succeeded.
    fn createResource2D(
        self: *VirtioGPU,
        resource_id: u32,
        pixel_format: PixelFormat,
        width: u32,
        height: u32,
    ) bool {
        self.builder.start();
        const rqst = self.builder.get(ResourceCreate2D);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
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

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceCreate2D), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    /// 2D resource destroy command.
    const ResourceDestroy = extern struct {
        header: ControlHeader,

        /// Id of resource to destroy.
        resource_id: u32,

        padding: u32,
    };

    /// Sends a 2D resoure destory command. Returns whether the operation succeeded.
    fn destroyResource(self: *VirtioGPU, resource_id: u32) bool {
        self.builder.start();
        const rqst = self.builder.get(ResourceDestroy);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
            .header = .{
                .header_type = .command_resource_unref,
                .fence_id = 0,
                .context_idx = 0,
                .ring_idx = 0,
                .flags = .{ .fence = false },
                .padding = .{ 0, 0, 0 },
            },
            .resource_id = resource_id,
            .padding = 0,
        };

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceDestroy), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    /// Resoure set scanout commnad.
    const ResourceSetScanout = extern struct {
        header: ControlHeader,

        /// Rectangle of the resource.
        rectangle: Rectangle,

        /// Selected display.
        scanout_id: u32,

        /// Resource for the scanout to use.
        resource_id: u32,
    };

    /// Set which resource the scanout is displaying. Returns whether the operation succeeded.
    fn setResourceScanout(
        self: *VirtioGPU,
        resource_id: u32,
        scanout_id: u32,
        rect: Rectangle,
    ) bool {
        self.builder.start();
        const rqst = self.builder.get(ResourceSetScanout);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
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

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceSetScanout), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    /// Transfer to host 2D command .
    const TransferToHost2D = extern struct {
        header: ControlHeader,

        /// Part of the resource which is transferred.
        rectangle: Rectangle,

        /// Destination offset.
        offset: u64,

        /// The resource to transfer from.
        resource_id: u32,

        padding: u32,
    };

    /// Transfers a part (or whole) of the resource to the host.
    /// Returns whether the operation succeeded.
    fn transferToHost2D(self: *VirtioGPU, resource_id: u32, offset: u64, rect: Rectangle) bool {
        self.builder.start();
        const rqst = self.builder.get(TransferToHost2D);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
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

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(TransferToHost2D), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    /// Flush resource command.
    const ResourceFlush = extern struct {
        header: ControlHeader,

        /// Size of resource.
        rectangle: Rectangle,

        /// Resource to flush.
        resource_id: u32,

        padding: u32,
    };

    /// Flushes a resource to the scanouts it is associated with.
    /// Returns whether the operation succeeded.
    fn flushResource(
        self: *VirtioGPU,
        resource_id: u32,
        rect: Rectangle,
    ) bool {
        self.builder.start();
        const rqst = self.builder.get(ResourceFlush);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
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

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceFlush), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    /// Attach resource backing commnad.
    const ResourceAttachBacking = extern struct {
        header: ControlHeader,

        /// Resource which we are attaching a backing to.
        resource_id: u32,

        /// Number of MemoryEntry-s that follow this struct.
        memory_entry_count: u32,
    };

    /// Attaches a framebuffer to a resource. Returns whether the operation succeeded.
    fn attachResourceBacking(
        self: *VirtioGPU,
        resource_id: u32,
        framebuffer_phys_addr: u64,
        framebuffer_size: u32,
    ) bool {
        const MemoryEntry = extern struct {
            address: u64,
            size: u32,
            padding: u32,
        };

        self.builder.start();
        const rqst = self.builder.get(ResourceAttachBacking);
        const mem_entry = self.builder.get(MemoryEntry);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
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

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceAttachBacking), 1, false);
        self.control_queue.writeDescriptor(1, mem_entry, @sizeOf(MemoryEntry), 2, false);
        self.control_queue.writeDescriptor(2, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    /// Detach resource backing command.
    const ResourceDetachBacking = extern struct {
        header: ControlHeader,
        resource_id: u32,
        padding: u32,
    };

    /// Detaches the framebuffer attached to a resource. Returns whether the operation scuceeded.
    fn detachResourceBacking(self: *VirtioGPU, resource_id: u32) bool {
        self.builder.start();
        const rqst = self.builder.get(ResourceDetachBacking);
        const resp = self.builder.get(ControlHeader);

        rqst.* = .{
            .header = .{
                .header_type = .command_resource_detach_backing,
                .fence_id = 0,
                .context_idx = 0,
                .ring_idx = 0,
                .flags = .{ .fence = false },
                .padding = .{ 0, 0, 0 },
            },
            .resource_id = resource_id,
            .padding = 0,
        };

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceDetachBacking), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ControlHeader), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        return resp.header_type == .response_ok_nodata;
    }

    // TODO: missing get_capset_info and get_capset

    /// Resource assign UUID command.
    const ResourceAssignUUID = extern struct {
        header: ControlHeader,

        /// Which resource to assign a UUID to.
        resource_id: u32,

        padding: u32,
    };

    /// Resource assign UUID command response.
    const ResourceAssignUUIDResponse = extern struct {
        header: ControlHeader,
        uuid: [8]u8,
    };

    /// Assigns a UUID to a resource. Returns the response.
    /// If the resource UUID feature was not negotiated
    /// or the scanout number is invalid then null is returned.
    /// Otherise returns the successful response.
    /// The return pointer is only valid until the next builder.start() call.
    fn assignResourceUUID(self: *VirtioGPU, resource_id: u32) ?*ResourceAssignUUIDResponse {
        if (self.negotiated_features & feature_resource_uuid == 0)
            return null;

        self.builder.start();
        const rqst = self.builder.get(ResourceAssignUUID);
        const resp = self.builder.get(ResourceAssignUUIDResponse);

        rqst.* = .{
            .header = .{
                .header_type = .command_resource_assign_uuid,
                .fence_id = 0,
                .context_idx = 0,
                .ring_idx = 0,
                .flags = .{ .fence = false },
                .padding = .{ 0, 0, 0 },
            },
            .resource_id = resource_id,
            .padding = 0,
        };

        self.control_queue.writeDescriptor(0, rqst, @sizeOf(ResourceAssignUUID), 1, false);
        self.control_queue.writeDescriptor(1, resp, @sizeOf(ResourceAssignUUIDResponse), null, true);

        self.control_queue.queueChainSingle(&self.virtio_device, 0, true);

        if (resp.header_type != .response_ok_resource_uuid)
            return null;

        return resp;
    }

    // TODO: missing resource_create_blob and set_scanout_blob
};

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
