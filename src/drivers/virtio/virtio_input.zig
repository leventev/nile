//! https://elixir.bootlin.com/linux/v7.0.12/source/drivers/input/evdev.c
//! https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/input-event-codes.h

const std = @import("std");
const Module = @import("../../Module.zig");
const pcie = @import("../bus/pcie.zig");
const device = @import("../../device.zig");
const mm = @import("../../mem/mm.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");
const arch = @import("../../arch/arch.zig");
const virtio = @import("virtio.zig");
const interrupt = @import("../../interrupt.zig");
const input = @import("../../input.zig");
const Thread = @import("../../Thread.zig");
const scheduler = @import("../../scheduler.zig");
const DeviceFilesystem = @import("../../DeviceFilesystem.zig");

const VirtQueue = virtio.VirtQueue;
const VirtioDevice = virtio.VirtioDevice;

const log = std.log.scoped(.virtio_input);

const VirtioInput = struct {
    pci_device: *pcie.PCIDevice,
    virtio_device: VirtioDevice,
    negotiated_features: u128,
    event_queue_array: []VirtioInputEvent,
    event_queue: VirtQueue,
    status_queue: VirtQueue,
    event_last_desc_idx: u16,
    soft_interrupt_thread: *Thread,

    fn readName(self: *VirtioInput) []const u8 {
        const device_config = self.virtio_device.device_base.asPtr(*VirtioInputDevice);
        device_config.select = .id_name;
        device_config.subselect = 0;
        return device_config.data.string[0..device_config.size];
    }

    fn readSerial(self: *VirtioInput) []const u8 {
        const device_config = self.virtio_device.device_base.asPtr(*VirtioInputDevice);
        device_config.select = .id_serial;
        device_config.subselect = 0;
        return device_config.data.string[0..device_config.size];
    }

    fn readDevIDs(self: *VirtioInput) ?*VirtioInputDevice.DevIDs {
        const device_config = self.virtio_device.device_base.asPtr(*VirtioInputDevice);
        device_config.select = .id_devids;
        device_config.subselect = 0;

        if (device_config.size < @sizeOf(VirtioInputDevice.DevIDs))
            return null;

        return &device_config.data.dev_ids;
    }

    fn readPropertyBits(self: *VirtioInput) ?*VirtioInputDevice.Property {
        const device_config = self.virtio_device.device_base.asPtr(*VirtioInputDevice);
        device_config.select = .property_bits;
        device_config.subselect = 0;

        if (device_config.size == 0) return null;

        return @ptrCast(@alignCast(&device_config.data.bitmap[0]));
    }

    fn readEventBits(self: *VirtioInput, event: VirtioInputDevice.EventSelect) []const u8 {
        const device_config = self.virtio_device.device_base.asPtr(*VirtioInputDevice);
        device_config.select = .event_bits;
        device_config.subselect = @intFromEnum(event);

        return device_config.data.bitmap[0..device_config.size];
    }
};

pub var virtio_input_device: VirtioInput = undefined;

const VirtioInputDevice = extern struct {
    select: ConfigSelect,
    subselect: u8,
    size: u8,
    reserved: [5]u8,
    data: extern union {
        string: [128]c_char,
        bitmap: [128]u8,
        abs: AbsoluteInfo,
        dev_ids: DevIDs,
    },

    const AbsoluteInfo = extern struct {
        min: u32,
        max: u32,
        fuzz: u32,
        flat: u32,
        res: u32,
    };

    const DevIDs = extern struct {
        bus_type: u16,
        vendor: u16,
        product: u16,
        version: u16,
    };

    const ConfigSelect = enum(u8) {
        unset = 0,
        id_name = 1,
        id_serial = 2,
        id_devids = 3,
        property_bits = 0x10,
        event_bits = 0x11,
        abs_info = 0x12,
    };

    const EventSelect = enum(u8) {
        syn = 0x00,
        key = 0x01,
        rel = 0x02,
        abs = 0x03,
        msc = 0x04,
        sw = 0x05,
        led = 0x11,
        snd = 0x12,
        rep = 0x14,
        ff = 0x15,
        pwr = 0x16,
        ff_status = 0x17,
    };

    // techinically it could be more than u8 but its pointless
    const Property = packed struct(u8) {
        pointer: bool,
        direct: bool,
        buttonpad: bool,
        semi_mt: bool,
        topbuttonpad: bool,
        pointer_stick: bool,
        accelerometer: bool,
        pressurepad: bool,
    };
};

const VirtioInputEvent = extern struct {
    event_type: EventType,
    code: u16,
    value: u32,

    const EventType = enum(u16) {
        syn = 0x00,
        key = 0x01,
        rel = 0x02,
        abs = 0x03,
        msc = 0x04,
        sw = 0x05,
        led = 0x11,
        snd = 0x12,
        rep = 0x14,
        ff = 0x15,
        pwr = 0x16,
        ff_status = 0x17,
    };
};

fn init(dev: *device.Device, devfs: *DeviceFilesystem) void {
    _ = devfs;
    const pci_dev = pcie.pciDeviceFromDevice(dev);
    const cfg_space = pcie.ConfigurationSpace.fromAddress(pci_dev.address);
    const header = cfg_space.generalHeader();
    const features = virtio.initializeVirtioDevice(pci_dev, &virtio_input_device.virtio_device, 0);

    virtio_input_device.pci_device = pci_dev;
    header.common_header.command.bus_master_enable = true;
    header.common_header.command.interrupt_disable = false;

    // const device_event_bits = input.readEventBits(.key);
    // log.debug("device event bits: {any}", .{device_event_bits});

    // TODO: detect what kind of device this is

    virtio_input_device.negotiated_features = features orelse @panic("Failed to initialize VirtIO device");

    const buffer_phys = buddy_allocator.allocBlock(0) catch unreachable;
    const virt_addr = mm.physicalToVirtualAddress(buffer_phys);
    const arr = virt_addr.asPtr([*]VirtioInputEvent);

    const event_buff_count = arch.page_size / @sizeOf(VirtioInputEvent);

    const event_queue_id = 0;
    const status_queue_id = 1;

    virtio_input_device.event_queue = VirtQueue.setup(
        virtio_input_device.virtio_device.common,
        event_queue_id,
        event_buff_count,
        .{ .no_interrupt = false },
    ) catch @panic("TODO");

    const event_buff_count_used = virtio_input_device.event_queue.queue_count;
    virtio_input_device.event_queue_array = arr[0..event_buff_count_used];

    virtio_input_device.status_queue = VirtQueue.setup(
        virtio_input_device.virtio_device.common,
        status_queue_id,
        null,
        .{ .no_interrupt = true },
    ) catch @panic("TODO");

    virtio_input_device.virtio_device.common.device_status.driver_ok = true;

    virtio_input_device.pci_device.device.interrupt = .{
        .number = virtio_input_device.pci_device.interrupt_number orelse @panic("TODO"),
        .handler = handleInterrupt,
    };

    virtio_input_device.soft_interrupt_thread = scheduler.newSoftInterruptHandler(
        softInterrupt,
        &virtio_input_device.pci_device.device,
    ) catch @panic("TODO");

    for (0..event_buff_count_used) |i| {
        virtio_input_device.event_queue.writeDescriptor(
            @intCast(i),
            &arr[i],
            @sizeOf(VirtioInputEvent),
            null,
            true,
        );
    }

    virtio_input_device.event_queue.queueChainRange(
        &virtio_input_device.virtio_device,
        0,
        virtio_input_device.event_queue.queue_count,
        false,
    );
}

fn softInterrupt(dev: *device.Device) void {
    _ = dev;

    // TODO: this assumes VIRTIO_F_IN_ORDER which is not negotiated

    const virtio_input = &virtio_input_device;
    const used_ring_idx = virtio_input.event_queue.used_ring_header.index;

    var index = virtio_input.event_last_desc_idx;
    const ev_count = used_ring_idx - index;

    while (index < used_ring_idx) : (index +%= 1) {
        const desc_index = index % virtio_input.event_queue.queue_count;

        const ev = virtio_input_device.event_queue_array[desc_index];

        switch (ev.event_type) {
            .key => {
                input.addKeyEvent(.{
                    .event_type = @enumFromInt(ev.value),
                    .key = @enumFromInt(ev.code),
                });
            },
            else => {},
        }
    }

    virtio_input.event_last_desc_idx = index;

    const avail_ring_idx = virtio_input.event_queue.available_ring_header.index +% ev_count;
    virtio_input.event_queue.queueChainCommon(&virtio_input.virtio_device, avail_ring_idx, false);
}

fn handleInterrupt(dev: *device.Device) void {
    _ = dev;

    scheduler.queueSoftInterruptHandler(virtio_input_device.soft_interrupt_thread);

    // clear the interrupt flag
    const virtio_input = &virtio_input_device;
    const isr = virtio_input.virtio_device.isr_base.asPtr(*volatile u8);
    _ = isr.*;
}

const device_ids: []const pcie.PCIDevice.Id = &.{
    .{ .vendor_id = 0x1af4, .device_id = 0x1052 },
};

pub const module: Module = .{
    .name = "virtio-input",
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
