//! https://www.redhat.com/en/blog/virtqueues-and-virtio-ring-how-data-travels
//! https://docs.oasis-open.org/virtio/virtio/v1.4/virtio-v1.4.pdf

const std = @import("std");
const pcie = @import("../bus/pcie.zig");
const mm = @import("../../mem/mm.zig");
const arch = @import("../../arch/arch.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");

const log = std.log.scoped(.virtio);

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

    /// Returns the physical address of bar + offset
    fn getPhysicalAddress(
        self: *VirtioPCICapability,
        general_header: *pcie.GeneralHeaderType,
    ) mm.PhysicalAddress {
        // TODO: would this work on 32 bit?
        const bar32 = general_header.bars[self.bar];
        const bar32_addr = bar32 & ~@as(u64, 0b1111);

        const bar_addr = if (bar32 & pcie.bar_type_mask == pcie.bar_type32)
            bar32_addr
        else if (bar32 & pcie.bar_type_mask == pcie.bar_type64)
            std.math.shl(u64, general_header.bars[self.bar + 1], 32) + bar32_addr
        else
            @panic("Invalid BAR type");

        return .fromInt(bar_addr + self.offset);
    }
};

/// 64 bit extension of VirtioPCICapability.
pub const VirtioPCICapability64 = extern struct {
    /// Base capability.
    cap: VirtioPCICapability,

    /// Upper 32 bits of the offset.
    offset_high: u32,

    /// Upper 32 bits of the size.
    size_high: u32,
};

/// Notification capability structure. It immediately follows the PCI capability header.
pub const VirtioPCINotification = extern struct {
    /// Base capability.
    pci_capability: VirtioPCICapability,

    /// Size of an entry in the notifications array.
    /// If zero all virtqueues share the same entry.
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
    queue_count: u16,

    /// Set by the driver for virtqueue notifications.
    queue_msix_vector: u16,

    /// Whether the queue is enabled. 1 is enabled, 0 is disabled.
    queue_enable: u16,

    /// Offset in notification_offset_multiplier units
    /// from the start of the Notification structure.
    queue_notify_offset: u16,

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

/// Vendor specific PCI capability. It immediately follows the PCI capability header.
pub const VirtioPCIVendor = extern struct {
    /// Base capability.
    cap: VirtioPCICapability,

    /// Identifies the structure.
    configuration_type: u8,

    /// Identifies the vendor specific format.
    /// Uses the PCI-SIG assigned vendor IDs.
    vendor_id: u16,
};

// TODO: support more transport modes other than PCI

/// Describes a Virtio device.
pub const VirtioDevice = struct {
    /// The common PCI capability, the data it points to is the main
    /// configuration structure for a virtio device.
    common_capability: *const VirtioPCICapability,

    /// Common configuration structure.
    common: *VirtioPCICommon,

    /// The notification PCI capability, after the capability structure
    /// is the notification multiplier. The data it points to is an array
    /// of u16s (but padded to notification multiplier size) and the index
    /// is the notify_off field of a virtqueue.
    notification_capability: *const VirtioPCINotification,

    /// Base address of the notification array.
    notification_base: mm.VirtualAddress,

    // TODO: the specification is very vague and talks about an 8 bit status
    // while the table they show is 32 bits wide
    isr_capability: *const VirtioPCICapability,

    // TODO:
    isr_base: mm.VirtualAddress,

    /// The device specific PCI capability. The data it points to is
    /// device specific configuration.
    device_capability: *const VirtioPCICapability,

    /// Address of device specific structure within the BAR.
    device_base: mm.VirtualAddress,

    /// Shared memory regions allocated by the device.
    /// They reside in the BAR described by the capability.
    shared_memory: [max_shared_memory_count]struct {
        /// Shared memory capability.
        cap: *const VirtioPCICapability64,

        /// The address inside the BAR.
        address: mm.VirtualAddress,

        /// The size of the shared memory region.
        size: u64,
    },

    /// The number of shared memory regions the device provided.
    shared_memory_count: usize,

    /// Optional vendor specific capability.
    /// It can be pointer casted to the vendor specific structure.
    vendor: [max_vendor_specific_count]struct {
        /// Vendor capability.
        capability: *const VirtioPCIVendor,

        /// Address of vendor specific structure within the BAR.
        address: mm.VirtualAddress,
    },

    /// The number of vendor specific structure the device provided.
    vendor_specific_count: usize,

    /// This was chosen arbitrarily, there could possibly be
    /// more regions than this.
    const max_shared_memory_count = 8;

    /// This was chosen arbitrarily, there could possibly be more
    /// vendor specific structures than this.
    const max_vendor_specific_count = 8;
};

pub const feature_indirect_descriptors = 1 << 28;
pub const feature_event_index = 1 << 29;
pub const feature_version_1 = 1 << 32;
pub const feature_access_platform = 1 << 33;
pub const feature_ring_packed = 1 << 34;
pub const feature_in_order = 1 << 35;
pub const feature_order_platform = 1 << 36;
pub const feature_sr_iov = 1 << 37;
pub const feature_notification_data = 1 << 38;
pub const feature_notification_config_data = 1 << 39;
pub const feature_ring_reset = 1 << 40;
pub const feature_admin_virtqueue = 1 << 41;
pub const feature_suspend = 1 << 43;

/// Initializes a virtio device on a PCI bus. Returns the negotiated features.
pub fn initializeVirtioDevice(
    pci_dev: *const pcie.PCIDevice,
    virt_dev: *VirtioDevice,
    device_feature_bits: u128,
) ?u128 {
    const cfg_space = pcie.ConfigurationSpace.fromAddress(pci_dev.address);
    const header = cfg_space.generalHeader();

    var common_found = false;
    var notify_found = false;
    var isr_found = false;
    var device_specific_found = false;
    virt_dev.shared_memory_count = 0;
    virt_dev.vendor_specific_count = 0;

    var cap_it = pcie.PCICapability.iterator(cfg_space, header.capabilities_pointer);
    while (cap_it.next()) |capability| {
        if (capability.vendor_id != .vendor_specific) continue;

        const virtio_cap: *VirtioPCICapability = @ptrCast(@alignCast(capability));
        const data_phys = virtio_cap.getPhysicalAddress(header);
        const data_virt = mm.physicalToVirtualAddress(data_phys);

        switch (virtio_cap.configuration_type) {
            .common => {
                virt_dev.common_capability = virtio_cap;
                virt_dev.common = @ptrFromInt(data_virt.asInt());
                common_found = true;
            },
            .notify => {
                virt_dev.notification_capability = @ptrCast(virtio_cap);
                virt_dev.notification_base = data_virt;
                notify_found = true;
            },
            .isr => {
                virt_dev.isr_capability = virtio_cap;
                virt_dev.isr_base = data_virt;
                isr_found = true;
            },
            .device => {
                virt_dev.device_capability = virtio_cap;
                virt_dev.device_base = data_virt;
                device_specific_found = true;
            },
            .shared_memory => {
                // TODO: maybe error?
                if (virt_dev.shared_memory_count == VirtioDevice.max_shared_memory_count)
                    @panic("Too many virtio shared memory regions");

                const cap64: *VirtioPCICapability64 = @ptrCast(virtio_cap);

                const off_upper: u64 = std.math.shl(u64, cap64.offset_high, 32);
                const off = off_upper | cap64.cap.offset;
                const size_upper: u64 = std.math.shl(u64, cap64.size_high, 32);
                const size = size_upper | cap64.cap.size;

                const address = data_virt.add(off);

                virt_dev.shared_memory[virt_dev.shared_memory_count] = .{
                    .cap = cap64,
                    .address = address,
                    .size = size,
                };

                virt_dev.shared_memory_count += 1;
            },
            .vendor => {
                virt_dev.vendor[virt_dev.vendor_specific_count] = .{
                    .capability = @ptrCast(virtio_cap),
                    .address = data_virt,
                };
            },
            .pci => log.warn("Unsupported alternative PCI configuration capability ignored", .{}),
        }
    }

    if (!common_found) {
        log.err("Common capability not found", .{});
        return null;
    }
    if (!notify_found) {
        log.err("Notify capability not found", .{});
        return null;
    }
    if (!isr_found) {
        log.err("ISR capability not found", .{});
        return null;
    }
    if (!device_specific_found) {
        log.err("Device specific capability not found", .{});
        return null;
    }

    const requested_dev_indep_features = feature_version_1;
    const requested_features = requested_dev_indep_features | device_feature_bits;

    virt_dev.common.device_status = .reset;
    virt_dev.common.device_status.acknowledge = true;
    virt_dev.common.device_status.driver = true;

    const negotiatied_features = negotiateFeatures(virt_dev.common, requested_features);

    virt_dev.common.device_status.features_ok = true;

    // check whether the device accepted the features
    std.debug.assert(virt_dev.common.device_status.features_ok);

    return negotiatied_features;
}

/// Read the feature bits the device supports then set the feature bits that the
/// driver requested and the vice supports. Returns the negotiated feature bits.
fn negotiateFeatures(common: *VirtioPCICommon, requested_features: u128) u128 {
    var negotiated_total: u128 = 0;
    for (0..4) |i| {
        common.device_feature_select = @intCast(i);
        const offered = common.device_feature;

        const requested_selected: u32 = @truncate(std.math.shr(u128, requested_features, i * 32));
        const negotiated = requested_selected & offered;

        common.driver_feature_select = @intCast(i);
        common.driver_feature = negotiated;

        negotiated_total |= negotiated;
        negotiated_total = std.math.shl(u128, negotiated, 32);
    }

    return negotiated_total;
}

/// Note that while the encapsulated structures are defined by the virtio standard,
/// this struct is not. It only exists for easier access to the virtqueue fields,
/// to avoid having to do pointer arithmetic every time we wanted to access them.
/// TODO: some space could be saved if we didnt store both the header and array pointers
pub const VirtQueue = struct {
    /// Queue id of the virtqueue that we write to common.queue_select
    queue_id: u16,

    /// The number of queues.
    queue_count: u16,

    /// Array of queue descriptors with queue_count elements.
    descriptor_table: [*]Descriptor,

    /// The header of the available ring.
    available_ring_header: *AvailableRingHeader,

    /// The ring which the driver writes the descriptor id of the head of a
    /// buffer chain to initiate a transaction. The device only reads this.
    /// This is directly after the available ring header but we save it for convenience.
    available_ring: [*]u16,

    /// The header of the used ring.
    used_ring_header: *UsedRingHeader,

    /// The ring which the devices writes to in order to signal that a
    /// request has been completed. The driver only reads this.
    /// This is directly after the used ring header but we save it for convenience.
    used_ring: [*]UsedElement,

    /// Writes the descriptor id of the head of a buffer chain to the available ring
    /// to start a transaction. Polls until the device advances the used ring index
    /// until the avaiable ring index, meaning the request's completion.
    pub fn queueChainSingle(self: *VirtQueue, virt_dev: *VirtioDevice, chain_descriptor_id: u16) void {
        std.debug.assert(chain_descriptor_id < self.queue_count);

        self.available_ring[self.available_ring_header.index % self.queue_count] = chain_descriptor_id;
        self.available_ring_header.index +%= 1;

        virt_dev.common.queue_select = self.queue_id;
        const notify_off = virt_dev.common.queue_notify_offset;
        const multiplier = virt_dev.notification_capability.notification_offset_multiplier;

        const notif_addr = virt_dev.notification_base.add(multiplier * notify_off);
        const notify_ptr: *u16 = notif_addr.asPtr(*u16);
        notify_ptr.* = 0;

        while (self.used_ring_header.index != self.available_ring_header.index) {}
    }

    /// Writes the descriptor id of the head of a buffer chain to the available ring
    /// to start a transaction. Polls until the device advances the used ring index
    /// until the avaiable ring index, meaning the request's completion.
    pub fn queueChainMultiple(
        self: *VirtQueue,
        virt_dev: *VirtioDevice,
        descriptor_chain_ids: []const u16,
    ) void {
        var new_index = self.available_ring_header.index;
        for (descriptor_chain_ids) |descriptor_id| {
            std.debug.assert(descriptor_id < self.queue_count);

            self.available_ring[new_index % self.queue_count] = descriptor_id;
            new_index +%= 1;
        }
        self.available_ring_header.index = new_index;

        virt_dev.common.queue_select = self.queue_id;
        const notify_off = virt_dev.common.queue_notify_offset;
        const multiplier = virt_dev.notification_capability.notification_offset_multiplier;

        const notif_addr = virt_dev.notification_base.add(multiplier * notify_off);
        const notify_ptr: *u16 = notif_addr.asPtr(*u16);
        notify_ptr.* = 0;

        while (self.used_ring_header.index != self.available_ring_header.index) {}
    }

    /// Writes one element of a buffer chain.
    pub fn writeDescriptor(
        self: *VirtQueue,
        descriptor_id: u16,
        ptr: *anyopaque,
        size: u32,
        next_id: ?u16,
        write_only: bool,
    ) void {
        std.debug.assert(descriptor_id < self.queue_count);

        const phys = mm.virtualToPhysicalAddress(.fromInt(@intFromPtr(ptr)));

        self.descriptor_table[descriptor_id].address = phys.asInt();
        self.descriptor_table[descriptor_id].size = size;
        self.descriptor_table[descriptor_id].next = next_id orelse 0;
        self.descriptor_table[descriptor_id].flags = .{
            .has_next = next_id != null,
            .device_write = write_only,
            .indirect = false,
            .reserved = 0,
        };
    }

    /// Sets up a virtqueue. Allocates the descriptor table, avaiable ring and the used ring.
    /// Optionally overrides the queue size.
    pub fn setup(
        common_cap: *VirtioPCICommon,
        queue_id: u16,
        override_queue_count: ?u16,
        avail_ring_flags: AvailableRingHeader.Flags,
    ) !VirtQueue {
        common_cap.queue_select = queue_id;
        var queue_count = common_cap.queue_count;
        std.debug.assert(queue_count != 0);

        if (override_queue_count) |override| {
            if (queue_count < override) return error.InvalidOverride;

            common_cap.queue_count = override;
            queue_count = override;
        }

        const avail_ring_size = @as(usize, queue_count) * @sizeOf(u16);
        const used_ring_size = @as(usize, queue_count) * @sizeOf(UsedElement);
        const desc_tbl_size = @as(usize, queue_count) * @sizeOf(Descriptor);

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

        const desc_tbl = mem_virt.asPtr([*]Descriptor);
        mem_virt = mem_virt.add(desc_tbl_size);

        const avail_ring_header = mem_virt.asPtr(*AvailableRingHeader);
        mem_virt = mem_virt.add(@sizeOf(AvailableRingHeader));
        const avail_ring = mem_virt.asPtr([*]u16);
        mem_virt = mem_virt.add(avail_ring_total_size - @sizeOf(AvailableRingHeader));

        const used_ring_header = mem_virt.asPtr(*UsedRingHeader);
        mem_virt = mem_virt.add(@sizeOf(UsedRingHeader));
        const used_ring = mem_virt.asPtr([*]UsedElement);

        std.debug.assert(@intFromPtr(desc_tbl) % arch.page_size == 0);
        std.debug.assert(@intFromPtr(used_ring_header) % arch.page_size == 0);

        avail_ring_header.index = 0;
        avail_ring_header.flags = avail_ring_flags;
        used_ring_header.index = 0;

        common_cap.descriptor_queue = mm.virtualToPhysicalAddress(
            .fromInt(@intFromPtr(desc_tbl)),
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
            .queue_count = queue_count,
            .descriptor_table = desc_tbl,
            .available_ring_header = avail_ring_header,
            .available_ring = avail_ring,
            .used_ring_header = used_ring_header,
            .used_ring = used_ring,
        };
    }

    /// Descriptor for a buffer.
    pub const Descriptor = extern struct {
        /// Physical address of the buffer.
        address: u64,

        /// Size of the buffer.
        size: u32,

        /// Buffer flags.
        flags: Flags,

        /// Descriptor id of the next buffer in a chain.
        /// Set to 0 if this is the tail of the chain
        next: u16,

        /// Buffer flags.
        const Flags = packed struct(u16) {
            /// Whether there is a next buffer in the chain after this.
            has_next: bool,

            /// Whether the device can write to this (the driver can not).
            device_write: bool,

            /// Whether this buffer describes another descriptor table.
            indirect: bool,

            reserved: u13 = 0,
        };
    };

    /// The available ring header which the driver writes to in order to initiate transactions.
    /// It is a ring buffer that wraps around and the device reads.
    pub const AvailableRingHeader = extern struct {
        /// Flags.
        flags: Flags,

        /// The index of the next entry in the available ring the driver would write to.
        /// Starts from 0 and wraps around. When the driver wants to queue a buffer chain
        /// it advances this by one.
        index: u16,

        /// Flags.
        const Flags = packed struct(u16) {
            /// The device should not send an interrupt when it consumes a buffer.
            no_interrupt: bool,

            reserved: u15 = 0,
        };
    };

    /// The used ring header which the device writes to when it completed a request.
    /// It is a ring buffer that wraps around and the driver reads.
    pub const UsedRingHeader = extern struct {
        /// Flags.
        flags: Flags,

        /// The index of the next entry in the used ring that the device would write to.
        /// Starts from 0 and wraps around. When the device completes a requests it
        /// advances this by one.
        index: u16,

        /// Flags.
        pub const Flags = packed struct(u16) {
            /// The driver should not notify the device when it queues a transaction.
            no_notify: bool,

            reserved: u15 = 0,
        };
    };

    /// The element of the used ring, describes a completed request.
    pub const UsedElement = extern struct {
        /// The descriptor index of the head of the buffer chain.
        descriptor_index: u32,

        /// The number of bytes written into the buffer chain.
        size: u32,
    };
};
