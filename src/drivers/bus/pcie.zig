//! https://docs.zephyrproject.org/latest/build/dts/api/bindings/pcie/host/pci-host-ecam-generic.html
//! https://elixir.bootlin.com/linux/v7.0/source/Documentation/devicetree/bindings/pci/host-generic-pci.yaml
//! https://www.pedestrian.com.cn/_downloads/6610dafab545af8b9f2f2de779c6012c/PCIE_V1.1.pdf
//! https://www.devicetree.org/open-firmware/bindings/pci/pci1_6d.pdf
//! https://www.pedestrian.com.cn/_downloads/cde755483a819e060fc9169e9d71f191/PCIE_V5.0.pdf
//! https://blogs.oracle.com/linux/a-study-of-the-linux-kernel-pci-subsystem-with-qemu

const std = @import("std");
const devicetree = @import("../../dt/devicetree.zig");
const property = @import("../../dt/property.zig");
const mm = @import("../../mem/mm.zig");
const Module = @import("../../Module.zig");
const device = @import("../../device.zig");
const slab_allocator = @import("../../mem/slab_allocator.zig");
const arch = @import("../../arch/arch.zig");
const DeviceFilesystem = @import("../../DeviceFilesystem.zig");

const log = std.log.scoped(.pcie);

/// Common header fields for every PCI device.
/// All fields are required if not specified otherwise.
pub const CommonHeader = extern struct {
    /// Manufacturer ID, possible values: https://pcisig.com/membership/member-companies.
    /// If the device does not exist 0xFFFF is returned.
    vendor_id: u16,

    /// Device ID
    device_id: u16,

    /// The device can be controlled with this register.
    command: Command,

    /// PCI bus related status.
    status: Status,

    /// Revision ID of the particular device. Valid values are arbitrarily allocated by the vendor.
    revision_id: u8,

    /// Programming Interface Byte. Optional.
    prog_if: u8,

    /// Complementary to class_code. Optional.
    subclass: u8,

    /// Specifies the function the device performs.
    class_code: ClassCode,

    /// Cache line size in 32-bit units. Optional.
    cache_line_size: u8,

    /// Latency timer expressed as PCI bus clocks. Optional.
    latency_timer: u8,

    /// The type of header that follows the common header.
    header_type: HeaderType,

    /// Built In Self Test status and control. Optional
    bist: u8,

    /// Value of vendor_id if the device does not exist.
    pub const no_device = 0xFFFF;

    /// Status register in the Common Header.
    pub const Status = packed struct(u16) {
        reserved1: u3,

        /// Set whenever there is an INTx interrupt message pending internally to the device.
        interrupt_status: bool,

        /// Hardwired to 1 on PCIe.
        capabilities_list: bool,

        /// Hardwired to 0 on PCIe.
        capable_66mhz: bool,

        reserved2: u1,

        /// Hardwired to 0 on PCIe.
        capable_fast_back_to_back: bool,

        /// See documentation.
        master_data_parity_error: bool,

        /// Hardwired to 0 on PCIe.
        devsel_timing: u2,

        /// Set when a target devices sends Target-Abort.
        signaled_target_abort: bool,

        /// Set when a master device receives a Target-Abort.
        received_target_abort: bool,

        /// Set when a master device receives a Master-Abort.
        received_master_abort: bool,

        /// Set when the device sent an ERR_FATAL or ERR_NONFATAL message and SERR# is enabled.
        signaled_system_error: bool,

        /// Set when the device detected a parity error.
        detected_parity_error: bool,
    };

    /// Command register in the Common Header.
    pub const Command = packed struct(u16) {
        /// Whether the device can respond to I/O space accesses
        io_space_access_respond: bool,

        /// Whether the device can respond to memspace accesses
        mem_space_access_respond: bool,

        /// Whether the device can issue memory and IO read/write requests.
        bus_master_enable: bool,

        /// Hardwired to 0 on PCIe.
        special_cycle_enable: bool,

        /// Hardwired to 0 on PCIe.
        memory_write_and_invalidate: bool,

        /// Hardwired to 0 on PCIe.
        vga_palette_snoop: bool,

        /// See documentation.
        parity_error_response: bool,

        /// Hardwired to 0 on PCIe.
        idsel_wait_cycle_control: bool,

        /// SERR# enable. Enables reporting of fatal and non-fatal errors.
        serr_enable: bool,

        /// Hardwired to 0 on PCIe.
        fast_back_to_back_enable: bool,

        /// Controls whether the device can generate INTx interrupt messages.
        interrupt_disable: bool,

        reserved2: u5,
    };

    /// Class code in the Common Header.
    pub const ClassCode = enum(u8) {
        unclassified = 0x0,
        mass_storage_controller = 0x1,
        network_controller = 0x2,
        display_controller = 0x3,
        multimedia_controller = 0x4,
        memory_controller = 0x5,
        bridge = 0x6,
        simple_communication_controller = 0x7,
        base_system_peripheral = 0x8,
        input_device_controller = 0x9,
        docking_station = 0xA,
        processor = 0xB,
        serial_bus_controller = 0xC,
        wireless_controller = 0xD,
        intelligent_controller = 0xE,
        satellite_communication_controller = 0xF,
        encryption_controller = 0x10,
        signal_processing_controller = 0x11,
        processing_accelerator = 0x12,
        non_essential_instrumentation = 0x13,
        co_processor = 0x40,
        unassigned = 0xFF,
    };

    pub const HeaderType = packed struct(u8) {
        header_type: enum(u2) {
            general_device = 0,
            pci_to_pci_bridge = 1,
            pci_to_cardbus_bridge = 2,
        },
        reserved: u5,
        multiple_function: bool,
    };
};

/// Describes capabilities of a PCI device.
/// Linked list whose head is contained in the PCI general header.
pub const PCICapability = extern struct {
    /// Vendor ID.
    vendor_id: CapabilityType,

    /// Offset of the next node in the configuration space.
    /// 0 at the end of the list.
    next: u8,

    /// Size of the capability in bytes.
    self_size: u8,

    /// Type of capability the node describes.
    pub const CapabilityType = enum(u8) {
        pci_power_management_interface = 1,
        agp = 2,
        vpd = 3,
        slot_identification = 4,
        message_signaled_interrupts = 5,
        compactpci_hot_swap = 6,
        pci_x = 7,
        hypertransport = 8,
        vendor_specific = 9,
        debug_port = 10,
        compactpci_resource_control = 11,
        pci_hot_plug = 12,
        pci_bridge_subsystem_vendor_id = 13,
        agp_8x = 14,
        secure_device = 15,
        pci_express = 16,
        msi_x = 17,
    };

    pub fn iterator(
        cfg_space: ConfigurationSpace,
        capabilities_ptr: u8,
    ) Iterator {
        return .{
            .cfg_space = cfg_space,
            .current_off = capabilities_ptr & ~@as(u8, 0b11),
        };
    }

    pub const Iterator = struct {
        cfg_space: ConfigurationSpace,
        current_off: u8,

        pub fn next(self: *Iterator) ?*PCICapability {
            if (self.current_off == 0) return null;

            const cap_ptr = self.cfg_space.getStruct(PCICapability, self.current_off);
            self.current_off = cap_ptr.next;

            return cap_ptr;
        }
    };
};

pub const bar_type_mask: u32 = 0b110;
pub const bar_type32 = 0b000;
pub const bar_type64 = 0b100;

/// Header type for general devices.
/// All fields are required if not specified otherwise.
pub const GeneralHeaderType = extern struct {
    /// Common header for all PCI devices.
    common_header: CommonHeader,

    /// Base address registers (BAR0-BAR5). Optional.
    bars: [6]u32,

    /// Points to the Card Information Structure.
    cardbus_cis_pointer: u32,

    /// Subsystem vendor id. Mostly required, see documentation.
    subsystem_vendor_id: u16,

    /// Subsystem id. Mostly required, see documentation.
    subsystem_id: u16,

    /// Optional.
    expansion_rom_base_address: u32,

    /// Optional.
    capabilities_pointer: u8,

    reserved1: u8,
    reserved2: u16,
    reserved3: u32,

    /// Which input of the system interrupt controllers the
    /// device's interrupt pin is connected to. Optional.
    interrupt_line: u8,

    /// Specifies which interrupt pin the device uses. 1 is INTA#, 2 is INTB# and so on.
    /// 0 means the device does not use an interrupt pin. Optional.
    interrupt_pin: u8,

    // See documentation. Optional.
    min_grant: u8,

    // See documentation. Optional.
    max_latency: u8,
};

/// Header type for PCI-to-PCI bridge devices.
/// All fields are required if not specified otherwise.
pub const PCIBridgeHeaderType = extern struct {
    /// Common header for all PCI devices.
    common_header: CommonHeader,

    /// Base address registers (BAR0-BAR1). Optional.
    bars: [2]u32,

    /// Not used.
    primary_bus_number: u8,

    /// Bus number of the PCI bus segment the secondary interface of the bridge is connected to.
    secondary_bus_number: u8,

    /// Bus number of the highest numbered PCI bus segment which is behind the bridge.
    subordinate_bus_number: u8,

    /// Not used.
    seconday_latency_timer: u8,

    /// Optional. See documentation.
    io_base: u8,

    /// Optional. See documentation.
    io_limit: u8,

    /// Secondary status register.
    secondary_status: CommonHeader.Status,

    /// Start of the range of memory transactions the bridge should forward.
    /// Only the upper 12 bits are used to form a 32 bit address where the bottom 20 bits are zero.
    memory_base: u16,

    /// End of the range of memory transactions the bridge should forward.
    /// Only the upper 12 bits are used to form a 32 bit address where the bottom 20 bits are zero.
    memory_limit: u16,

    /// Start of the range of prefetchable memory transactions the bridge should forward.
    /// Only the upper 12 bits are used to form a 32 bit address where the bottom 20 bits are zero.
    /// Optional.
    prefetchable_memory_base: u16,

    /// End of the range of prefetchable memory transactions the bridge should forward.
    /// Only the upper 12 bits are used to form a 32 bit address where the bottom 20 bits are zero.
    /// Optional.
    prefetchable_memory_limit: u16,

    /// Optional upper 32 bit extension to prefetchable_memory_base.
    prefetchable_memory_base_upper: u32,

    /// Optioanl upper 32 bit extension to prefetchable_memory_limit.
    prefetchable_memory_limit_upper: u32,

    /// Optional upper 16 bit extension to io_base.
    io_base_upper: u16,

    /// Optional upper 16 bit extension to io_limit.
    io_limit_upper: u16,

    /// Optional.
    capabilities_pointer: u8,

    reserved: [3]u8,

    /// TODO
    expansion_rom_base_address: u32,

    /// TODO
    interrupt_line: u8,

    /// TODO
    interrupt_pin: u8,

    /// Extension to the command register.
    bridge_control: BridgeControl,

    pub const BridgeControl = packed struct(u16) {
        parity_error_response_enable: bool,
        serr_enable: bool,
        isa_enable: bool,
        vga_enable: bool,
        vga_16bit_decode: bool,
        master_abort_mode: bool,
        secondary_bus_reset: bool,

        /// Not used. Hardwired to 0.
        fast_back_to_back_transactions_enable: bool,

        /// Not used. Hardwired to 0.
        primary_discard_timer: bool,

        /// Not used. Hardwired to 0.
        secondary_discard_timer: bool,

        /// Not used. Hardwired to 0.
        discard_timer_status: bool,

        /// Not used. Hardwired to 0.
        discard_timer_serr_enable: bool,

        reserved: u4,
    };
};

pub const config_space_size = 4096;

// NOTE: fields are all little endian so simply reading them on big endian
// would not work. but nothing noteworthy uses big endian anyways
pub const ConfigurationSpace = struct {
    data: []u8,

    pub inline fn fromAddress(
        addr: PCIDevice.Address,
    ) ConfigurationSpace {
        const shl = std.math.shl;

        const off = shl(u64, addr.bus, 20) + shl(u64, addr.device, 15) + shl(u64, addr.function, 12);
        const config_space_address = ecam_base_address.add(off);

        return .{
            .data = @as([*]u8, @ptrFromInt(config_space_address.asInt()))[0..config_space_size],
        };
    }

    pub inline fn commonHeader(self: ConfigurationSpace) *CommonHeader {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    pub inline fn generalHeader(self: ConfigurationSpace) *GeneralHeaderType {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    pub inline fn bridgeHeader(self: ConfigurationSpace) *PCIBridgeHeaderType {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    pub inline fn getStruct(self: ConfigurationSpace, comptime T: type, offset: usize) *T {
        return @ptrCast(@alignCast(self.data.ptr + offset));
    }
};

var ecam_base_address: mm.VirtualAddress = undefined;

const DTChildAddress = packed struct(u96) {
    low: u32,
    high: u32,
    register: u8,
    function: u3,
    device: u5,
    bus: u8,
    space_code: SpaceCode,
    reserved: u3,
    aliased: bool,
    prefetchable: bool,
    non_relocatable: bool,

    const SpaceCode = enum(u2) {
        configuration_space = 0,
        io_space = 1,
        memory_space32 = 2,
        memory_space64 = 3,
    };
};

const PCIMemory = struct {
    bridge_memory_start64: u64,
    bridge_memory_size64: u64,
    current64: u64,

    bridge_memory_start32: u32,
    bridge_memory_size32: u32,
    current32: u32,

    fn allocate32(self: *PCIMemory, size: u32) u32 {
        const alloc_size = @max(size, arch.page_size);
        const next_addr = if (self.current32 % alloc_size == 0)
            self.current32
        else
            self.current32 & (alloc_size - 1) + alloc_size;

        self.current32 = next_addr + alloc_size;
        std.debug.assert(self.current32 < self.bridge_memory_start32 + self.bridge_memory_size32);

        return next_addr;
    }

    fn allocate64(self: *PCIMemory, size: u64) u64 {
        const alloc_size = @max(size, arch.page_size);
        const next_addr = if (self.current64 % alloc_size == 0)
            self.current64
        else
            self.current64 & (alloc_size - 1) + alloc_size;

        self.current64 = next_addr + alloc_size;
        std.debug.assert(self.current64 < self.bridge_memory_start64 + self.bridge_memory_size64);

        return next_addr;
    }

    fn fillBars(self: *PCIMemory, config_space: ConfigurationSpace) void {
        const common = config_space.commonHeader();

        switch (common.header_type.header_type) {
            .general_device => {
                const general = config_space.generalHeader();
                var i: usize = 0;
                while (i < 6) {
                    common.command.mem_space_access_respond = false;

                    general.bars[i] = std.math.maxInt(u32);
                    const bar32 = general.bars[i];

                    const bar_type = bar32 & bar_type_mask;

                    if (bar_type == bar_type32) {
                        defer i += 1;
                        const masked = bar32 & ~@as(u32, 0b1111);
                        if (masked == 0) continue;

                        const size = ~masked + 1;

                        const mem = self.allocate32(size);
                        // TODO: write flags too?

                        common.command.mem_space_access_respond = true;
                        general.bars[i] = mem;
                    } else if (bar_type == bar_type64) {
                        defer i += 2;
                        general.bars[i + 1] = std.math.maxInt(u32);
                        const upper = general.bars[i + 1];
                        const full: u64 = std.math.shl(u64, @as(u64, upper), 32) | bar32;
                        const masked = full & ~@as(u64, 0b1111);
                        if (masked == 0) continue;

                        const size = ~masked + 1;

                        const mem = self.allocate64(size);
                        // TODO: write flags too?

                        common.command.mem_space_access_respond = true;
                        general.bars[i] = @truncate(mem);
                        general.bars[i + 1] = @intCast(std.math.shr(u64, mem, 32));
                    } else @panic("Invalid BAR type");
                }
            },
            .pci_to_pci_bridge => {},
            else => {},
        }
    }
};

/// Recursively enumerates the PCIe buses.
/// Starting from the root bus whenever a PCI-to-PCI bridge device is found,
/// we assign the next available bus id to it and start enumerating it.
/// Bridges are added as devices which have been matched to a driver.
/// Returns the number of buses behind the bridge,
/// for the root bus it is the total number of buses in the system.
fn enumerateBus(
    bus_id_counter: *u8,
    mem_pool: *PCIMemory,
    // TODO: dont pass this many parameters
    dt: *const devicetree.DeviceTree,
    int_map: *const property.InterruptMap,
    child_address_cells: u32,
    child_interrupt_cells: u32,
) u8 {
    const bus_id = bus_id_counter.*;
    var child_bus_counter: u8 = 0;

    var device_id: u8 = 0;
    while (device_id < 32) : (device_id += 1) {
        var function_id: u8 = 0;
        var check_functions = true;
        while (check_functions and function_id < 8) : (function_id += 1) {
            const dev_addr = PCIDevice.Address{
                .bus = bus_id,
                .device = @intCast(device_id),
                .function = @intCast(function_id),
            };

            const config_space = ConfigurationSpace.fromAddress(dev_addr);
            const common_header = config_space.commonHeader();
            if (common_header.vendor_id == CommonHeader.no_device)
                continue;

            if (function_id == 0 and !common_header.header_type.multiple_function)
                check_functions = false;

            var pci_device = device_cache.alloc() catch @panic("TODO: failed to alloc device cache");
            pci_device.address = dev_addr;
            pci_device.id = .{
                .vendor_id = common_header.vendor_id,
                .device_id = common_header.device_id,
            };
            pci_device.device.match_table = .{ .bus = &pcie_bus };
            pci_device.device.matched = common_header.header_type.header_type != .general_device;

            var name_buff = device_name_cache.alloc() catch @panic("TODO: failed to alloc device name cache");
            pci_device.device.name = std.fmt.bufPrint(
                name_buff[0..name_buff.len],
                "pci/{x:02}:{x:02}.{}",
                .{ bus_id, device_id, function_id },
            ) catch @panic("TODO: failed to format name");

            device.addDevice(&pci_device.device);

            mem_pool.fillBars(config_space);

            if (common_header.header_type.header_type == .general_device) {
                const general_header = config_space.generalHeader();

                var int_map_it = int_map.iterator(child_address_cells, child_interrupt_cells);
                while (int_map_it.next(dt)) |mapping| {
                    const addr: DTChildAddress = @bitCast(
                        @as(u96, @intCast(mapping.child_address)),
                    );

                    const bus_match = addr.bus == dev_addr.bus;
                    const device_match = addr.device == dev_addr.device;
                    const function_match = addr.function == dev_addr.function;
                    if (!bus_match or !device_match or !function_match)
                        continue;

                    if (mapping.child_interrupt_specifier != general_header.interrupt_pin)
                        continue;

                    pci_device.interrupt_number = @intCast(mapping.parent_interrupt_specifier);
                }
            }

            if (common_header.header_type.header_type != .pci_to_pci_bridge)
                continue;

            const bridge_header = config_space.bridgeHeader();

            bus_id_counter.* += 1;
            const child_bus_id = bus_id_counter.*;

            // for the PCI-to-PCI bridge to forward memory transactions we need to set
            // the secondary_bus_number to the bus number that is on its secondary
            // port. we also set the subordinate_bus_number to 0xFF so that all
            // memory transactions are forwarded in case the child bus also has child buses
            bridge_header.secondary_bus_number = child_bus_id;
            bridge_header.subordinate_bus_number = 0xFF;
            const child_bus_count = enumerateBus(
                bus_id_counter,
                mem_pool,
                dt,
                int_map,
                child_address_cells,
                child_interrupt_cells,
            );

            // after we know how many buses are behind the bridge we can
            // set its subordinate_bus_number to its actual value
            bridge_header.subordinate_bus_number = child_bus_id + child_bus_count;

            child_bus_counter = child_bus_count;
        }
    }

    return 1 + child_bus_counter;
}

fn init(
    dt: *const devicetree.DeviceTree,
    handle: u32,
    devfs: *DeviceFilesystem,
) error{InvalidDeviceTree}!void {
    _ = devfs;

    const node = dt.nodes.items[handle];

    const ranges = node.getProperty(.ranges) orelse
        @panic("Devicetree PCI node is required to contain .ranges field");

    const reg = node.getProperty(.reg) orelse
        @panic("Devicetree PCI node is required to contain .reg field");

    const parent_address_cells = node.getAddressCellFromParent(dt);
    const parent_size_cells = node.getSizeCellFromParent(dt);
    const child_address_cells = node.getAddressCell();
    const child_size_cells = node.getSizeCell();
    const child_interrupt_cells = node.getProperty(.interrupt_cells) orelse @panic("TODO: child interrupt cells");

    const interrupt_map = node.getProperty(.interrupt_map) orelse
        @panic("Devicetree PCI node does not have .interrupt_map field");

    // TODO
    std.debug.assert(parent_address_cells <= 2 and parent_size_cells <= 2);

    var ranges_it = ranges.iterator(parent_address_cells, child_address_cells, child_size_cells) catch @panic("TODO: pci ranges_it");
    // TODO: figure out how to handle this. the spec is very vague and i noticed that
    // all bus, device, function, register numbers are zero. and why is there an io_space defined?
    // im assuming this region is global to all PCI devices

    var bridge_memory_start64: u64 = undefined;
    var bridge_memory_size64: u64 = undefined;
    var bridge_memory_start32: u32 = undefined;
    var bridge_memory_size32: u32 = undefined;
    var found_bridge_memory64 = false;
    var found_bridge_memory32 = false;

    while (ranges_it.next()) |range| {
        const child: DTChildAddress = @bitCast(@as(u96, @intCast(range.child_address)));
        if (child.space_code == .memory_space64) {
            bridge_memory_start64 = @intCast(range.parent_address);
            bridge_memory_size64 = @intCast(range.size);
            found_bridge_memory64 = true;
        } else if (child.space_code == .memory_space32) {
            bridge_memory_start32 = @intCast(range.parent_address);
            bridge_memory_size32 = @intCast(range.size);
            found_bridge_memory32 = true;
        }
    }

    // TODO: this entire PCIMemory solution is very ugly
    var pci_memory = PCIMemory{
        .bridge_memory_start64 = bridge_memory_start64,
        .bridge_memory_size64 = bridge_memory_size64,
        .current64 = bridge_memory_start64,
        .bridge_memory_start32 = bridge_memory_start32,
        .bridge_memory_size32 = bridge_memory_size32,
        .current32 = bridge_memory_start32,
    };

    if (!(found_bridge_memory64 and found_bridge_memory32)) @panic("PCI bridge memory not found");

    var reg_it = reg.iterator(parent_address_cells, parent_size_cells) catch @panic("TODO: pci reg_it");

    const first_reg = reg_it.next() orelse return error.InvalidDeviceTree;

    const ecam_base_phys = mm.PhysicalAddress.fromInt(@intCast(first_reg.address));
    ecam_base_address = mm.physicalToVirtualAddress(ecam_base_phys);

    device.addBus(&pcie_bus);

    device_cache = slab_allocator.createObjectCache(PCIDevice);
    device_name_cache = slab_allocator.createObjectCache([11]u8);

    var bus_id_counter: u8 = 0;
    const bus_count_total = enumerateBus(
        &bus_id_counter,
        &pci_memory,
        dt,
        &interrupt_map,
        child_address_cells,
        child_interrupt_cells,
    );
    std.log.debug("{} buses in total", .{bus_count_total});

    // const ecam_size = first_reg.size;
    // _ = ecam_size;
}

pub inline fn pciDeviceFromDevice(dev: *device.Device) *PCIDevice {
    const pci_device: *PCIDevice = @fieldParentPtr("device", dev);
    return pci_device;
}

pub inline fn pciDeviceFromDeviceConst(dev: *const device.Device) *const PCIDevice {
    const pci_device: *const PCIDevice = @fieldParentPtr("device", dev);
    return pci_device;
}

fn pciMatch(dev: *const device.Device, mod: *const Module) bool {
    const pci_device = pciDeviceFromDeviceConst(dev);

    const bus_info = mod.module_type.device_driver.bus;
    std.debug.assert(@intFromPtr(bus_info.bus_type) == @intFromPtr(&pcie_bus));

    const device_ids_ptr: [*]const PCIDevice.Id = @ptrCast(@alignCast(bus_info.device_ids));
    const device_ids: []const PCIDevice.Id = device_ids_ptr[0..bus_info.device_id_count];

    for (device_ids) |mod_dev_id| {
        const vendor_match = pci_device.id.vendor_id == mod_dev_id.vendor_id;
        const device_match = pci_device.id.device_id == mod_dev_id.device_id;
        if (vendor_match and device_match)
            return true;
    }

    return false;
}

pub const pcie_bus = device.Bus{
    .name = "pcie",
    .match = pciMatch,
};

pub const PCIDevice = struct {
    id: Id,
    address: Address,
    device: device.Device,

    /// Which (system-wide) IRQ the interrupt in the interrupt pin field
    /// corresponds to.
    interrupt_number: ?usize,

    pub const Id = struct {
        vendor_id: u16,
        device_id: u16,
    };

    pub const Address = struct {
        bus: u8,
        device: u5,
        function: u3,
    };
};

var device_cache: slab_allocator.ObjectCache(PCIDevice) = undefined;

// pci/00:00.0 - 11 chars
var device_name_cache: slab_allocator.ObjectCache([11]u8) = undefined;

pub const module: Module = .{
    .name = "pcie",
    .module_type = .{
        .device_driver = .{
            .devicetree = .{
                .compatible = &.{"pci-host-ecam-generic"},
                .init = init,
            },
        },
    },
};
