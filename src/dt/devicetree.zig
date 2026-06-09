// documentation: https://github.com/devicetree-org/devicetree-specification

const std = @import("std");
const root = @import("root");
const property = @import("property.zig");
const Module = @import("../Module.zig");
const device = @import("../device.zig");
const slab_allocator = @import("../mem/slab_allocator.zig");

const kio = root.kio;
const config = root.config;

const Property = property.Property;
const PropertyType = property.PropertyType;

const blob_magic_idx = 0x0;
const total_size_idx = 0x1;
const dt_structs_offset_idx = 0x2;
const dt_strings_offset_idx = 0x3;
const mem_rsvmap_offset_idx = 0x4;
const version_idx = 0x5;
const last_compatible_version_idx = 0x6;
const boot_cpu_id_phys_idx = 0x7;
const dt_strings_size_idx = 0x8;
const dt_structs_size_idx = 0x9;

const prop_value_len_idx = 0x0;
const prop_name_offset_idx = 0x1;
const prop_value_idx = 0x2;

const TokenType = enum(u32) {
    begin_node = 1,
    end_node = 2,
    property = 3,
    nop = 4,
    end = 9,
};

const device_tree_blob_magic = 0xD00DFEED;

// TODO: consider changing it to a ?u32, but that would increase the size
const no_parent = std.math.maxInt(u32);

const bigToNative = std.mem.bigToNative;

var device_cache: slab_allocator.ObjectCache(device.Device) = undefined;

fn getString(blob: []const u32, offset: u32) [*:0]const u8 {
    const string_block_offset = bigToNative(u32, blob[dt_strings_offset_idx]);
    const string_block_start = @as([*]const u8, @ptrCast(blob.ptr)) + @as(usize, string_block_offset);
    return @ptrCast(string_block_start + @as(usize, offset));
}

fn readToken(tok: u32) TokenType {
    const token_val = bigToNative(u32, tok);
    return @enumFromInt(token_val);
}

fn readBeginNode(ptr: [*]u32) []const u8 {
    const node_name_ptr: [*:0]const u8 = @ptrCast(ptr);
    const node_name: []const u8 = std.mem.span(node_name_ptr);
    return node_name;
}

pub const DeviceTreeNode = struct {
    properties: std.ArrayListUnmanaged(Property),
    children: std.ArrayListUnmanaged(Child),
    parent_handle: u32,

    const Child = struct {
        name: []const u8,
        handle: u32,
    };

    const Self = @This();

    fn PropReturnType(comptime prop_type: PropertyType) type {
        const typeInfo = @typeInfo(Property);
        const fields = typeInfo.@"union".fields;
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(prop_type))) {
                return field.type;
            }
        }
    }

    pub fn getProperty(self: Self, comptime prop_type: PropertyType) ?PropReturnType(prop_type) {
        for (self.properties.items) |prop| {
            switch (prop) {
                prop_type => |val| return val,
                else => continue,
            }
        }
        return null;
    }

    pub fn getPropertyOther(self: Self, name: []const u8) ?[]const u8 {
        for (self.properties.items) |prop| {
            switch (prop) {
                .other => |inner| {
                    if (std.mem.eql(u8, inner.name, name))
                        return inner.value;
                },
                else => continue,
            }
        }

        return null;
    }

    pub fn getPropertyOtherU32(self: Self, name: []const u8) ?u32 {
        const val = self.getPropertyOther(name) orelse return null;
        return std.mem.readInt(u32, val[0..4], .big);
    }

    pub fn getChildNameFromHandle(self: DeviceTreeNode, handle: usize) ?[]const u8 {
        for (self.children.items) |child| {
            if (child.handle == handle) return child.name;
        }
        return null;
    }

    const default_address_cells = 2;
    const default_size_cells = 1;

    pub fn getAddressCell(self: DeviceTreeNode) u32 {
        return self.getProperty(.address_cells) orelse default_address_cells;
    }

    pub fn getSizeCell(self: DeviceTreeNode) u32 {
        return self.getProperty(.size_cells) orelse default_size_cells;
    }

    pub fn getAddressCellFromParent(self: DeviceTreeNode, dt: *const DeviceTree) u32 {
        if (self.parent_handle == no_parent) return default_address_cells;

        const parent = &dt.nodes.items[self.parent_handle];
        return parent.getAddressCell();
    }

    pub fn getSizeCellFromParent(self: DeviceTreeNode, dt: *const DeviceTree) u32 {
        if (self.parent_handle == no_parent) return default_size_cells;

        const parent = &dt.nodes.items[self.parent_handle];
        return parent.getSizeCell();
    }
};

pub const DeviceTree = struct {
    /// list of nodes, 0 should be the root node
    nodes: std.ArrayListUnmanaged(DeviceTreeNode),

    blob: []const u32,

    phandle_table: std.AutoArrayHashMapUnmanaged(u32, u32),

    pub fn root(self: DeviceTree) *const DeviceTreeNode {
        std.debug.assert(self.nodes.items.len > 0);
        return &self.nodes.items[0];
    }

    pub fn getChild(self: DeviceTree, node: *const DeviceTreeNode, name: []const u8) ?*const DeviceTreeNode {
        for (node.children.items) |child|
            if (std.mem.eql(u8, child.name, name))
                return &self.nodes.items[child.handle];
        return null;
    }

    pub fn getNodeName(self: DeviceTree, handle: usize) []const u8 {
        if (handle == no_parent) {
            return "/";
        }

        const node = self.nodes.items[handle];
        const parent = self.nodes.items[node.parent_handle];

        return parent.getChildNameFromHandle(handle) orelse unreachable;
    }
};

const PropertyRead = struct { prop: Property, len: usize };
fn readProperty(blob: []const u32, ptr: [*]u32) PropertyRead {
    const value_len = bigToNative(u32, ptr[prop_value_len_idx]);
    const name_offset = bigToNative(u32, ptr[prop_name_offset_idx]);

    const name = getString(blob, name_offset);
    const value = @as([*]const u8, @ptrCast(&ptr[prop_value_idx]))[0..value_len];
    const name_slice = std.mem.span(name);

    var prop: Property = undefined;

    if (std.mem.eql(u8, name_slice, "compatible")) {
        prop = .{ .compatible = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "model")) {
        prop = .{ .model = value };
    } else if (std.mem.eql(u8, name_slice, "phandle")) {
        prop = .{ .phandle = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "status")) {
        prop = .{ .status = value };
    } else if (std.mem.eql(u8, name_slice, "#address-cells")) {
        prop = .{ .address_cells = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "#size-cells")) {
        prop = .{ .size_cells = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "reg")) {
        prop = .{ .reg = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "virtual-reg")) {
        prop = .{ .other = .{ .name = name_slice, .value = value } };
    } else if (std.mem.eql(u8, name_slice, "ranges")) {
        prop = .{ .ranges = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "dma-ranges")) {
        prop = .{ .dma_ranges = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "dma-coherent")) {
        prop = .{ .dma_coherent = {} };
    } else if (std.mem.eql(u8, name_slice, "dma-noncoherent")) {
        prop = .{ .dma_noncoherent = {} };
    } else if (std.mem.eql(u8, name_slice, "interrupts")) {
        prop = .{ .interrupts = value };
    } else if (std.mem.eql(u8, name_slice, "interrupt-parent")) {
        prop = .{ .interrupt_parent = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "interrupts-extended")) {
        prop = .{ .interrupts_extended = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "#interrupt-cells")) {
        prop = .{ .interrupt_cells = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "interrupt-controller")) {
        prop = .{ .interrupt_controller = {} };
    } else if (std.mem.eql(u8, name_slice, "interrupt-map")) {
        prop = .{ .interrupt_map = value };
    } else if (std.mem.eql(u8, name_slice, "interrupt-map-mask")) {
        prop = .{ .interrupt_map_mask = value };
    } else if (std.mem.eql(u8, name_slice, "clock-frequency")) {
        const val = switch (value.len) {
            @sizeOf(u64) => std.mem.readInt(u64, value[0..8], .big),
            else => std.mem.readInt(u32, value[0..4], .big),
        };
        prop = .{ .clock_frequency = val };
    } else if (std.mem.eql(u8, name_slice, "timebase-frequency")) {
        const val = switch (value.len) {
            @sizeOf(u64) => std.mem.readInt(u64, value[0..8], .big),
            else => std.mem.readInt(u32, value[0..4], .big),
        };
        prop = .{ .timebase_frequency = val };
    } else {
        prop = .{
            .other = .{
                .name = name_slice,
                .value = value,
            },
        };
    }

    return PropertyRead{ .prop = prop, .len = value.len };
}

fn readNode(allocator: std.mem.Allocator, dt: *DeviceTree, node_handle: u32, ptr: [*]u32) !usize {
    var ptr_idx: usize = 0;
    var continue_reading = true;

    // NOTE: we do not need to errdefer deallocate the allocated memory
    // since if we can't parse the device tree the kernel should halt thus
    // freeing the memory is unnecessary

    while (continue_reading) {
        const tokenType: TokenType = readToken(ptr[ptr_idx]);
        ptr_idx += 1;
        switch (tokenType) {
            .begin_node => {
                const name = readBeginNode(ptr + ptr_idx);
                ptr_idx += std.math.divCeil(usize, name.len + 1, @sizeOf(u32)) catch unreachable;

                const child_handle: u32 = @intCast(dt.nodes.items.len);
                try dt.nodes.append(allocator, .{
                    .children = std.ArrayListUnmanaged(DeviceTreeNode.Child).empty,
                    .properties = std.ArrayListUnmanaged(Property).empty,
                    .parent_handle = node_handle,
                });

                const read = try readNode(allocator, dt, child_handle, ptr + ptr_idx);
                ptr_idx += read;

                try dt.nodes.items[node_handle].children.append(allocator, DeviceTreeNode.Child{
                    .name = name,
                    .handle = child_handle,
                });
            },
            .property => {
                const prop_read = readProperty(dt.blob, ptr + ptr_idx);
                const words = std.math.divCeil(usize, prop_read.len, @sizeOf(u32)) catch unreachable;
                ptr_idx += 2 + words;

                try dt.nodes.items[node_handle].properties.append(allocator, prop_read.prop);

                if (prop_read.prop == .phandle) {
                    try dt.phandle_table.put(allocator, prop_read.prop.phandle, node_handle);
                }
            },
            .nop => {},
            .end, .end_node => continue_reading = false,
        }
    }

    return ptr_idx;
}

pub fn printDeviceTree(
    path: []const u8,
    dt_root: *const DeviceTree,
    handle: u32,
    depth: usize,
) void {
    const node = dt_root.nodes.items[handle];

    const space_count = depth * 4;
    var space_buf: [256]u8 = undefined;
    for (0..space_count) |i| {
        space_buf[i] = ' ';
    }

    std.log.info("{s}{s}:", .{ space_buf[0..space_count], path });

    // TODO: determine a good buffer size
    var prop_buff: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(prop_buff[0..]);
    for (node.properties.items) |prop| {
        writer.end = 0;
        prop.print(handle, dt_root, &writer) catch @panic("buffer too small");
        const str = writer.buffered();
        std.log.info("{s}{s}", .{ space_buf[0..space_count], str });
    }

    for (node.children.items) |child| {
        printDeviceTree(child.name, dt_root, child.handle, depth + 1);
    }
}

fn addDevice(
    dt: *const DeviceTree,
    node: *const DeviceTreeNode,
    handle: u32,
) !void {
    const compatible = node.getProperty(.compatible) orelse return;

    const node_name = blk: {
        if (node.parent_handle == no_parent) break :blk "/";
        const parent = dt.nodes.items[node.parent_handle];
        break :blk parent.getChildNameFromHandle(handle) orelse unreachable;
    };

    var dev = try device_cache.alloc();
    dev.name = node_name;
    dev.parent = null;
    dev.match_table = .{
        .devicetree = .{
            .compatible = compatible,
            .handle = handle,
        },
    };

    try device.addDevice(dev);

    // var it = compatible.iterator();
    // while (it.next()) |device_compatible| {
    //     for (Module.modules) |mod| {
    //         if (mod.initialized or mod.module.module_type != .device_driver) continue;
    //         switch (mod.module.module_type.device_driver) {
    //             .devicetree => |dt_mod| {
    //                 for (dt_mod.compatible) |driver_compatible| {
    //                     if (!std.mem.eql(u8, driver_compatible, device_compatible)) continue;
    //
    //                     dt_mod.init(dt, handle) catch |err| {
    //                         std.log.err("failed to initialize {s}: {s}", .{ mod.module.name, @errorName(err) });
    //                     };
    //                     std.log.info("Module '{s}'({s}) initialized", .{ mod.module.name, node_name });
    //
    //                     return;
    //                 }
    //             },
    //             else => {},
    //         }
    //     }
    // }
    //
    // var compBuff: [256]u8 = undefined;
    // var writer = std.Io.Writer.fixed(compBuff[0..]);
    // compatible.print(&writer) catch @panic("compatible string too long");
    // const allCompString = writer.buffered();
    //
    // std.log.warn(
    //     "Compatible driver not found for '{s}' compatible: '{s}'",
    //     .{ node_name, allCompString },
    // );
}

// pub fn initDriversFromDeviceTreeEarly(dt: *const DeviceTree) void {
//     for (dt.nodes.items, 0..) |*node, handle| {
//         if (node.getProperty(.interrupt_controller) == null) continue;
//         initDriverFromDeviceTree(dt, node, @intCast(handle));
//     }
// }

pub fn addDevices(dt: *const DeviceTree) !void {
    // TODO: dont use objectcache
    device_cache = slab_allocator.createObjectCache(device.Device);
    for (dt.nodes.items, 0..) |*node, handle| {
        if (node.getProperty(.interrupt_controller) != null) continue;
        try addDevice(dt, node, @intCast(handle));
    }
}

pub fn readDeviceTreeBlob(allocator: std.mem.Allocator, blobPtr: *void) !DeviceTree {
    const blob: [*]u32 = @ptrCast(@alignCast(blobPtr));
    const magic = bigToNative(u32, blob[blob_magic_idx]);
    if (magic != device_tree_blob_magic) {
        return error.MagicMismatch;
    }

    const blob_size = std.math.divCeil(u32, bigToNative(u32, blob[total_size_idx]), @sizeOf(u32)) catch unreachable;

    const struct_block_offset = bigToNative(u32, blob[dt_structs_offset_idx]);
    const struct_block_start = @as([*]u8, @ptrCast(blob)) + @as(usize, struct_block_offset);

    const token_ptr: [*]u32 = @ptrCast(@alignCast(struct_block_start));
    const token_type = readToken(token_ptr[0]);
    if (token_type != .begin_node)
        return error.InvalidDeviceTree;

    // name should be empty but we don't need to check
    const name = readBeginNode(token_ptr + 1);

    const words = std.math.divCeil(usize, name.len + 1, @sizeOf(u32)) catch unreachable;
    const ptr = token_ptr + 1 + words;

    var dt = DeviceTree{
        .nodes = std.ArrayList(DeviceTreeNode).empty,
        .blob = blob[0 .. blob_size / 4],
        .phandle_table = std.AutoArrayHashMapUnmanaged(u32, u32){},
    };

    try dt.nodes.append(allocator, .{
        .children = std.ArrayList(DeviceTreeNode.Child).empty,
        .properties = std.ArrayList(Property).empty,
        .parent_handle = no_parent,
    });

    const root_node_read = try readNode(allocator, &dt, 0, ptr);
    _ = root_node_read;

    return dt;
}
