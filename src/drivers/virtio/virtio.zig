//! https://www.redhat.com/en/blog/virtqueues-and-virtio-ring-how-data-travels
//! https://docs.oasis-open.org/virtio/virtio/v1.4/virtio-v1.4.html

const std = @import("std");
const pcie = @import("../bus/pcie.zig");
const mm = @import("../../mem/mm.zig");
const arch = @import("../../arch/arch.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");

/// Describes a VIRTIO capability.
/// Linked list whose head is contained in the PCI general header.
pub const VirtioPCICapability = extern struct {
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

    pub const ConfigurationType = enum(u8) {
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
pub const VirtioPCINotification = extern struct {
    pci_capability: VirtioPCICapability,
    notification_offset_multiplier: u32,
};

/// Common configuration structure.
pub const VirtioPCICommon = extern struct {
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

    pub const Status = packed struct(u8) {
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

pub const Capabilities = struct {
    common: *VirtioPCICommon,
    notification: *const VirtioPCINotification,
    notification_base_addr: mm.VirtualAddress,
};

pub fn initializeVirtioDevice(pci_dev: *const pcie.PCIDevice, caps: *Capabilities) bool {
    const cfg_space = pcie.ConfigurationSpace.fromAddress(pci_dev.address);
    const header = cfg_space.generalHeader();

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

    return true;
}

/// Note that while the encapsulated structures are defined by the virtio standard,
/// this struct is not. It only exists for easier access to the virtqueue fields,
/// to avoid having to do pointer arithmetic every time we wanted to access them.
pub const VirtQueue = struct {
    queue_id: u16,
    queue_size: u16,
    descriptor_table: []Descriptor,
    available_ring_header: *AvailableRingHeader,
    available_ring: []u16,
    used_ring_header: *UsedRingHeader,
    used_ring: []UsedElement,

    pub fn queueChain(self: *VirtQueue, caps: *Capabilities, chain_descriptor_id: u16) void {
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

    pub fn writeNextDescriptor(
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
    pub fn setup(
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
