//! https://docs.zephyrproject.org/latest/build/dts/api/bindings/pcie/host/pci-host-ecam-generic.html
//! https://elixir.bootlin.com/linux/v7.0/source/Documentation/devicetree/bindings/pci/host-generic-pci.yaml
//! https://www.pedestrian.com.cn/_downloads/6610dafab545af8b9f2f2de779c6012c/PCIE_V1.1.pdf

const std = @import("std");
const devicetree = @import("../dt/devicetree.zig");
const mm = @import("../mem/mm.zig");

/// Common header fields for every PCI device.
/// All fields are required if not specified otherwise.
const CommonHeader = extern struct {
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
    const no_device = 0xFFFF;

    /// Status register in the Common Header.
    const Status = packed struct(u16) {
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
    const Command = packed struct(u16) {
        reserved1: u2,

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
    const ClassCode = enum(u8) {
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

    const HeaderType = packed struct(u8) {
        header_type: enum(u2) {
            general_device = 0,
            pci_to_pci_bridge = 1,
            pci_to_cardbus_bridge = 2,
        },
        reserved: u5,
        multiple_function: bool,
    };
};

inline fn configSpace(
    ecam_base_address: mm.VirtualAddress,
    bus: u8,
    device: u5,
    function: u3,
) []const u8 {
    const config_space_size = 4096;
    const shl = std.math.shl;

    const offset = shl(u64, bus, 20) + shl(u64, device, 15) + shl(u64, function, 12);

    const addr = ecam_base_address.add(offset);
    return @as([*]u8, @ptrFromInt(addr.asInt()))[0..config_space_size];
}

pub fn initDriver(dt: *const devicetree.DeviceTree, handle: u32) !void {
    const node = dt.nodes.items[handle];

    const ranges = node.getProperty(.ranges) orelse
        @panic("Devicetree PCI node is required to contain .ranges field");
    const reg = node.getProperty(.reg) orelse
        @panic("Devicetree PCI node is required to contain .reg field");

    const parent_address_cells = node.getAddressCellFromParent(dt);
    const parent_size_cells = node.getSizeCellFromParent(dt);
    // TODO
    std.debug.assert(parent_address_cells <= 2 and parent_size_cells <= 2);
    var reg_it = try reg.iterator(parent_address_cells, parent_size_cells);

    const first_reg = reg_it.next() orelse return error.InvalidDeviceTre;

    const ecam_base_phys = mm.PhysicalAddress.fromInt(@intCast(first_reg.address));
    const ecam_base_virt = mm.physicalToVirtualAddress(ecam_base_phys);

    for (0..256) |bus| {
        for (0..32) |device| {
            for (0..8) |function| {
                const config_space = configSpace(
                    ecam_base_virt,
                    @intCast(bus),
                    @intCast(device),
                    @intCast(function),
                );

                var reader = std.Io.Reader.fixed(config_space);

                const header = reader.takeStruct(CommonHeader, .little) catch @panic("TODO");
                if (header.vendor_id == CommonHeader.no_device) continue;

                std.log.debug("{}/{}/{}: {any}", .{ bus, device, function, header });
            }
        }
    }
    const ecam_size = first_reg.size;

    _ = ecam_size;
    _ = ranges;
}
