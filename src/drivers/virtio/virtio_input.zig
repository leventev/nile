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

const VirtQueue = virtio.VirtQueue;
const VirtioDevice = virtio.VirtioDevice;

const log = std.log.scoped(.virtio_input);

const VirtioInput = struct {
    virtio_device: VirtioDevice,
    negotiated_features: u128,
    event_queue: VirtQueue,
    status_queue: VirtQueue,

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

var input: VirtioInput = undefined;

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

fn init(dev: *const device.Device) void {
    const pci_dev = pcie.pciDeviceFromDevice(dev);
    const cfg_space = pcie.ConfigurationSpace.fromAddress(pci_dev.address);
    const header = cfg_space.generalHeader();
    log.debug("INT PIN: {}", .{header.interrupt_pin});
    const features = virtio.initializeVirtioDevice(pci_dev, &input.virtio_device, 0);

    // std.log.debug("VIRTIO INPUT {any}", .{input.virtio_device.device_specific});

    const device_name = input.readName();
    log.debug("device name: {s}", .{device_name});

    const device_serial = input.readSerial();
    log.debug("device serial: {s}", .{device_serial});

    const device_devids = input.readDevIDs();
    if (device_devids) |devids| {
        log.debug("device ids: {any}", .{devids});
    }

    const device_prop_bits = input.readPropertyBits();
    if (device_prop_bits) |prop_bits| {
        log.debug("device prop bits: {any}", .{prop_bits});
    }

    const device_event_bits = input.readEventBits(.key);
    log.debug("device event bits: {any}", .{device_event_bits});

    input.negotiated_features = features orelse @panic("Failed to initialize VirtIO device");

    const event_queue_id = 0;
    const status_queue_id = 1;

    input.event_queue = VirtQueue.setup(
        input.virtio_device.common,
        event_queue_id,
        null,
        .{ .no_interrupt = false },
    ) catch @panic("TODO");

    input.status_queue = VirtQueue.setup(
        input.virtio_device.common,
        status_queue_id,
        null,
        .{ .no_interrupt = true },
    ) catch @panic("TODO");

    input.virtio_device.common.device_status.driver_ok = true;

    const buffer_phys = buddy_allocator.allocBlock(0) catch unreachable;
    const virt_addr = mm.physicalToVirtualAddress(buffer_phys);
    const arr = virt_addr.asPtr([*]VirtioInputEvent);

    const count = 10;
    for (0..count) |i| {
        input.event_queue.writeDescriptor(
            @intCast(i),
            &arr[i],
            @sizeOf(VirtioInputEvent),
            null,
            true,
        );
    }
    input.event_queue.queueChainMultiple(&input.virtio_device, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    std.log.debug("{any}", .{arr[0..count]});
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
