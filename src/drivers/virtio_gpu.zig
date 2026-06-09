const std = @import("std");
const Module = @import("../Module.zig");
const pcie = @import("bus/pcie.zig");

const device_ids: []const pcie.PCIDevice.Id = &.{
    .{ .vendor_id = 0x1af4, .device_id = 0x1050 },
};

fn init() void {
    std.log.debug("VIRTIO GPU INIT", .{});
}

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
