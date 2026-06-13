const std = @import("std");
const slab_allocator = @import("mem/slab_allocator.zig");
const property = @import("dt/property.zig");
const Module = @import("Module.zig");
const devicetree = @import("dt/devicetree.zig");
const interrupt = @import("interrupt.zig");

/// A bus that devices and drivers are associated with.
pub const Bus = struct {
    /// Name of the bus.
    name: []const u8,

    /// Tries to match the device to the module by checking whether the device's ID
    /// is compatible with the module's. The device must be associated with the bus.
    /// The Device struct is usually encapsulated in a bigger bus specific struct
    /// which can be obtained with @fieldParentPtr.
    match: *const fn (dev: *const Device, mod: *const Module) bool,
};

const max_buses = 8;
var buses: [max_buses]*const Bus = undefined;
var bus_count: usize = 0;

pub fn addBus(bus: *const Bus) void {
    for (buses[0..bus_count]) |existing_bus| {
        if (std.mem.eql(u8, bus.name, existing_bus.name)) {
            @panic("TODO: handle this nicely, however this shouldnt be turned into an error");
        }
    }

    buses[bus_count] = bus;
}

pub const Device = struct {
    name: []const u8,
    matched: bool = false,
    interrupt_number: ?u32 = null,
    parent: ?*Device,
    match_table: union(enum) {
        devicetree: struct {
            handle: u32,
            compatible: property.Compatible,
        },
        bus: *const Bus,
    },
    next: ?*Device,
};

// TODO: LOCKING
var devices: ?*Device = null;

pub fn dumpDevices() void {
    var device_ptr = devices;

    std.log.debug("Devices:", .{});
    // TODO: print a tree using parent ptr
    while (device_ptr) |device| : (device_ptr = device.next) {
        std.log.debug("\t{s}", .{device.name});
    }
}

pub fn addDevice(dev: *Device) void {
    var next_ptr = &devices;

    while (next_ptr.*) |existing_dev| : (next_ptr = &existing_dev.next) {
        if (std.mem.eql(u8, dev.name, existing_dev.name)) {
            @panic("TODO: handle this nicely, however this shouldnt be turned into an error");
        }
    }

    next_ptr.* = dev;
    dev.next = null;
}

pub fn matchDeviceTreeDevices(dt: *const devicetree.DeviceTree) void {
    var device_ptr = devices;
    dev_loop: while (device_ptr) |device| : (device_ptr = device.next) {
        if (device.matched) continue;

        const dev_dt_info = switch (device.match_table) {
            .devicetree => |dt_info| dt_info,
            else => continue,
        };

        for (&Module.modules) |*module| {
            // TODO: support multiple devices using the same driver
            if (module.initialized) continue;

            const device_driver = switch (module.module_type) {
                .device_driver => |driver| driver,
                else => continue,
            };

            const driver_dt_info = switch (device_driver) {
                .devicetree => |dt_info| dt_info,
                else => continue,
            };

            var dev_comp_it = dev_dt_info.compatible.iterator();
            while (dev_comp_it.next()) |device_compatible| {
                for (driver_dt_info.compatible) |driver_compatible| {
                    if (!std.mem.eql(u8, driver_compatible, device_compatible)) continue;

                    driver_dt_info.init(dt, dev_dt_info.handle) catch |err| {
                        std.log.err("failed to initialize {s}: {s}", .{
                            module.name,
                            @errorName(err),
                        });
                        continue :dev_loop;
                    };

                    std.log.info("Module '{s}'({s}) initialized", .{ module.name, device.name });
                    module.initialized = true;

                    continue :dev_loop;
                }
            }
        }

        var comp_buff: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(comp_buff[0..]);
        dev_dt_info.compatible.print(&writer) catch @panic("compatible string too long");
        const all_comp_string = writer.buffered();

        std.log.warn(
            "Compatible driver not found for '{s}' compatible: '{s}'",
            .{ device.name, all_comp_string },
        );
    }
}

pub fn matchNonDeviceTreeDevices() bool {
    const prev_bus_count = bus_count;

    var device_ptr = devices;
    while (device_ptr) |device| : (device_ptr = device.next) {
        if (device.matched) continue;

        const device_bus = switch (device.match_table) {
            .bus => |bus| bus,
            else => continue,
        };

        for (&Module.modules) |*module| {
            // TODO: support multiple devices using the same driver
            if (module.initialized) continue;

            const device_driver = switch (module.module_type) {
                .device_driver => |driver| driver,
                else => continue,
            };

            const driver_bus_info = switch (device_driver) {
                .bus => |bus_info| bus_info,
                else => continue,
            };

            if (driver_bus_info.bus_type != device_bus) continue;
            const success = driver_bus_info.bus_type.match(device, module);
            if (!success) continue;

            driver_bus_info.init(device);
            module.initialized = true;
            device.matched = true;
        }
    }

    return prev_bus_count != bus_count;
}

pub fn enableInterrupts() void {
    var device_ptr = devices;
    while (device_ptr) |device| : (device_ptr = device.next) {
        std.log.debug("->NOT MATCHED {s}", .{device.name});
        if (!device.matched) continue;
        std.log.debug("->{s}", .{device.name});

        if (device.interrupt_number) |int_num| {
            std.log.debug("enable interrut #{} for {s}", .{ int_num, device.name });
            interrupt.enableInterrupt(int_num) catch @panic("Failed to enable interrupt");
            interrupt.setPriority(int_num, 1) catch @panic("Failed to set priority");
        }
    }
}
