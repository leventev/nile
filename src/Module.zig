const std = @import("std");
const fs = @import("fs.zig");
const devicetree = @import("dt/devicetree.zig");
const device = @import("device.zig");

const DeviceTree = devicetree.DeviceTree;

const Module = @This();

/// Name of the module. Must be unique.
name: []const u8,

/// The type of the module.
module_type: union(Type) {
    /// The module is a device driver that is matched to a device.
    device_driver: union(enum) {
        /// The device driver is matched to a device described in the device tree.
        devicetree: struct {
            /// The devices the driver is compatible with.
            compatible: []const []const u8,

            /// The function that is called when a driver is successfully matched to a device.
            init: *const fn (dt: *const DeviceTree, handle: u32) error{InvalidDeviceTree}!void,
        },
        /// The device driver is matched to a device on a bus.
        bus: struct {
            /// Pointer to the bus that driver's compatible devices are on.
            bus_type: *const device.Bus,

            /// Array of bus specific device IDs the driver supports.
            device_ids: *const anyopaque,

            /// Number of device IDs in 'device_ids'.
            device_id_count: usize,

            /// The function that is called when a driver is successfully matched to a device.
            /// The Device struct is usually encapsulated in a bigger bus specific struct
            /// which can be obtained with @fieldParentPtr.
            init: *const fn (device: *const device.Device) void,
        },
    },
    /// The module is a file system.
    fs: *fs.FileSystem,
},

/// Set when the driver has been initialized.
/// TODO: support multiple devices using the same driver
initialized: bool = false,

/// The type of the module.
const Type = enum {
    device_driver,
    fs,
};

const module_source_files: []const type = &.{
    @import("drivers/fs/ramfs.zig"),
    @import("drivers/uart.zig"),
    @import("drivers/bus/pcie.zig"),
    @import("drivers/virtio/virtio_gpu.zig"),
    @import("drivers/virtio/virtio_input.zig"),
};

pub var modules = blk: {
    // TODO: copying the Modules is not a nice solution
    var mods: [module_source_files.len]Module = undefined;
    for (0.., module_source_files) |i, module_source_file| {
        if (!@hasDecl(module_source_file, "module")) {
            @compileError("Module '" ++ @typeName(module_source_file) ++ "' does not have a .module defined");
        }

        var module_definition = @field(module_source_file, "module");
        if (@TypeOf(module_definition) != Module) {
            @compileError("Module '" ++ @typeName(module_source_file) ++ ".module' is not of type Module");
        }

        module_definition.initialized = false;

        mods[i] = module_definition;
    }

    break :blk mods;
};
