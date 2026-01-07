// documentation: https://github.com/devicetree-org/devicetree-specification

const kio = @import("kio.zig");
const std = @import("std");

const config = @import("config.zig");

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

const no_parent = std.math.maxInt(u32);

const bigToNative = std.mem.bigToNative;

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

    const PropertyType = enum {
        compatible,
        model,
        phandle,
        status,
        address_cells,
        size_cells,
        reg,
        virtual_reg,
        ranges,
        dma_ranges,
        dma_coherent,
        dma_noncoherent,
        interrupts,
        interrupt_parent,
        interrupts_extended,
        interrupt_cells,
        interrupt_controller,
        interrupt_map,
        interrupt_map_mask,
        clock_frequency,
        timebase_frequency,
        other,
    };

    const Property = union(PropertyType) {
        compatible: Compatible,
        model: []const u8,
        phandle: u32,
        status: []const u8,
        address_cells: u32,
        size_cells: u32,
        reg: Reg,
        virtual_reg: Reg,
        ranges: []const u8, // TODO
        dma_ranges: []const u8, // TODO
        dma_coherent: void,
        dma_noncoherent: void,
        interrupts: []const u8,
        interrupt_parent: u32,
        interrupts_extended: InterruptsExtended,
        interrupt_cells: u32,
        interrupt_controller: void,
        interrupt_map: []const u8, // TODO
        interrupt_map_mask: []const u8, // TODO
        clock_frequency: u64,
        timebase_frequency: u64,
        other: struct {
            name: []const u8,
            value: []const u8,
        },

        pub const InterruptsExtended = struct {
            buff: []const u8,

            pub fn iterator(self: InterruptsExtended, dt: *const DeviceTree) Iterator {
                return Iterator{
                    .buff = self.buff,
                    .idx = 0,
                    .size_cells = 1,
                    .dt = dt,
                };
            }

            pub fn print(self: InterruptsExtended, dt: *const DeviceTree, writer: anytype) !void {
                var it = self.iterator(dt);
                var first = true;
                while (it.next()) |int| {
                    if (first) {
                        first = false;
                    } else {
                        _ = try writer.writeByte(' ');
                    }

                    const name = dt.getNodeName(int.handle);
                    try std.fmt.format(writer, "<&{s} 0x{x}>", .{ name, int.int_specifier });
                }
            }

            pub const Iterator = struct {
                buff: []const u8,
                idx: usize,
                size_cells: usize,
                dt: *const DeviceTree,

                pub fn next(self: *Iterator) ?Interrupt {
                    if (self.idx == self.buff.len) return null;
                    const phandle = std.mem.readInt(u32, @ptrCast(&self.buff[self.idx]), .big);

                    self.idx += 4;
                    // TODO: better error handling
                    const handle = self.dt.phandle_table.get(phandle) orelse @panic("invalid phandle");

                    const int_specifier: u64 = switch (self.size_cells) {
                        1 => std.mem.readInt(u32, @ptrCast(&self.buff[self.idx]), .big),
                        2 => std.mem.readInt(u64, @ptrCast(&self.buff[self.idx]), .big),
                        else => @panic("unsupported cell size"),
                    };

                    self.idx += self.size_cells * 4;

                    return Interrupt{
                        .handle = handle,
                        .int_specifier = int_specifier,
                    };
                }
            };

            const Interrupt = struct {
                handle: u32,
                int_specifier: u64,
            };
        };

        pub const Compatible = struct {
            buff: []const u8,

            pub fn iterator(self: Compatible) Iterator {
                return .{
                    .buff = self.buff,
                    .idx = 0,
                };
            }

            pub const Iterator = struct {
                buff: []const u8,
                idx: usize,

                pub fn next(self: *Iterator) ?[]const u8 {
                    if (self.idx == self.buff.len) return null;
                    const str = std.mem.sliceTo(self.buff[self.idx..], '\x00');
                    self.idx += str.len + 1;
                    return str;
                }
            };

            pub fn print(self: Compatible, writer: anytype) !void {
                var it = self.iterator();
                var first = true;
                while (it.next()) |comp| {
                    if (first) {
                        first = false;
                    } else {
                        _ = try writer.writeByte(' ');
                    }

                    _ = try writer.write(comp);
                }
            }
        };

        pub const Reg = struct {
            buff: []const u8,

            pub fn print(self: Reg, writer: anytype, address_cells: u32, size_cells: u32) !void {
                var it = try self.iterator(address_cells, size_cells);
                var first = true;
                _ = try writer.writeByte('<');
                while (it.next()) |reg| {
                    if (first) {
                        first = false;
                    } else {
                        _ = try writer.writeByte(' ');
                    }

                    if (size_cells == 0) {
                        try std.fmt.format(writer, "0x{x}", .{reg.addr});
                    } else {
                        try std.fmt.format(writer, "0x{x} 0x{x}", .{ reg.addr, reg.size });
                    }
                }
                _ = try writer.writeByte('>');
            }

            pub fn iterator(self: Reg, address_cells: u32, size_cells: u32) !Iterator {
                const entry_size = address_cells + size_cells;
                const rem = std.math.mod(usize, self.buff.len, entry_size) catch
                    return error.InvalidCellCounts;
                if (rem != 0)
                    return error.InvalidCellCounts;

                return .{
                    .buff = self.buff,
                    .address_cells = address_cells,
                    .size_cells = size_cells,
                    .idx = 0,
                };
            }

            pub const Iterator = struct {
                buff: []const u8,
                address_cells: u32,
                size_cells: u32,
                idx: u32,

                pub fn next(self: *Iterator) ?RegPair {
                    if (self.idx == self.buff.len) return null;

                    const addr: u64 = switch (self.address_cells) {
                        1 => std.mem.readInt(u32, @ptrCast(&self.buff[self.idx]), .big),
                        2 => std.mem.readInt(u64, @ptrCast(&self.buff[self.idx]), .big),
                        else => @panic("unsupported cell size"),
                    };

                    self.idx += @sizeOf(u32) * self.address_cells;

                    const size: u64 = switch (self.size_cells) {
                        0 => 0,
                        1 => std.mem.readInt(u32, @ptrCast(&self.buff[self.idx]), .big),
                        2 => std.mem.readInt(u64, @ptrCast(&self.buff[self.idx]), .big),
                        else => @panic("unsupported cell size"),
                    };

                    self.idx += @sizeOf(u32) * self.size_cells;

                    return .{
                        .addr = addr,
                        .size = size,
                    };
                }
            };

            const RegPair = struct {
                addr: u64,
                size: u64,
            };
        };

        pub fn print(self: Property, handle: u32, dt: *const DeviceTree, writer: anytype) !void {
            switch (self) {
                .compatible => {
                    _ = try writer.write("compatible = ");
                    try self.compatible.print(writer);
                },
                .model => |val| {
                    try std.fmt.format(writer, "model = {s}", .{val});
                },
                .phandle => |val| {
                    try std.fmt.format(writer, "phandle = {}", .{val});
                },
                .status => |val| {
                    try std.fmt.format(writer, "status = {s}", .{val});
                },
                .address_cells => |val| {
                    try std.fmt.format(writer, "address_cells = {}", .{val});
                },
                .size_cells => |val| {
                    try std.fmt.format(writer, "size_cells = {}", .{val});
                },
                .reg => {
                    const node = dt.nodes.items[handle];
                    const address_cells = node.getAddressCellFromParent(dt) orelse
                        return error.InvalidDeviceTree;
                    const size_cells = node.getSizeCellFromParent(dt) orelse
                        return error.InvalidDeviceTree;

                    _ = try writer.write("reg = ");
                    try self.reg.print(writer, address_cells, size_cells);
                },
                .virtual_reg => {
                    const node = dt.nodes.items[handle];
                    const address_cells = node.getAddressCellFromParent(dt) orelse
                        return error.InvalidDeviceTree;
                    const size_cells = node.getSizeCellFromParent(dt) orelse
                        return error.InvalidDeviceTree;

                    _ = try writer.write("virtual_reg = ");
                    try self.reg.print(writer, address_cells, size_cells);
                },
                .interrupts => |val| {
                    _ = try std.fmt.format(writer, "interrupts = {any}", .{val});
                },
                .interrupts_extended => {
                    _ = try writer.write("interrupts_extended = ");
                    try self.interrupts_extended.print(dt, writer);
                },
                .interrupt_parent => |val| {
                    const parent_handle = dt.phandle_table.get(val) orelse
                        return error.InvalidDeviceTree;
                    try std.fmt.format(writer, "interrupt_parent = <&{s}>", .{dt.getNodeName(parent_handle)});
                },
                .interrupt_cells => |val| {
                    try std.fmt.format(writer, "interrupt_cells = {}", .{val});
                },
                .interrupt_controller => {
                    try std.fmt.format(writer, "interrupt_controller;", .{});
                },
                .clock_frequency => |val| {
                    try std.fmt.format(writer, "clock_frequency = {}", .{val});
                },
                .timebase_frequency => |val| {
                    try std.fmt.format(writer, "timebase_frequency = {}", .{val});
                },
                .other => |val| {
                    try std.fmt.format(writer, "{s} = {any}", .{ val.name, val.value });
                },
                else => @panic("UNIMPLEMENTED"),
            }
        }
    };

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

    pub fn getAddressCellFromParent(self: DeviceTreeNode, dt: *const DeviceTree) ?u32 {
        if (self.parent_handle == no_parent) return null;

        const parent = &dt.nodes.items[self.parent_handle];
        return parent.getProperty(.address_cells) orelse
            parent.getAddressCellFromParent(dt);
    }

    pub fn getSizeCellFromParent(self: DeviceTreeNode, dt: *const DeviceTree) ?u32 {
        if (self.parent_handle == no_parent) return null;

        const parent = &dt.nodes.items[self.parent_handle];
        return parent.getProperty(.address_cells) orelse
            parent.getSizeCellFromParent(dt);
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

const PropertyRead = struct { prop: DeviceTreeNode.Property, len: usize };
fn readProperty(blob: []const u32, ptr: [*]u32) PropertyRead {
    const value_len = bigToNative(u32, ptr[prop_value_len_idx]);
    const name_offset = bigToNative(u32, ptr[prop_name_offset_idx]);

    const name = getString(blob, name_offset);
    const value = @as([*]const u8, @ptrCast(&ptr[prop_value_idx]))[0..value_len];
    const name_slice = std.mem.span(name);

    var prop: DeviceTreeNode.Property = undefined;

    if (std.mem.eql(u8, name_slice, "compatible")) {
        prop = DeviceTreeNode.Property{ .compatible = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "model")) {
        prop = DeviceTreeNode.Property{ .model = value };
    } else if (std.mem.eql(u8, name_slice, "phandle")) {
        prop = DeviceTreeNode.Property{ .phandle = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "status")) {
        prop = DeviceTreeNode.Property{ .status = value };
    } else if (std.mem.eql(u8, name_slice, "#address-cells")) {
        prop = DeviceTreeNode.Property{ .address_cells = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "#size-cells")) {
        prop = DeviceTreeNode.Property{ .size_cells = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "reg")) {
        prop = DeviceTreeNode.Property{ .reg = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "virtual-reg")) {
        prop = DeviceTreeNode.Property{ .other = .{ .name = name_slice, .value = value } };
    } else if (std.mem.eql(u8, name_slice, "ranges")) {
        prop = DeviceTreeNode.Property{ .ranges = value };
    } else if (std.mem.eql(u8, name_slice, "dma-ranges")) {
        prop = DeviceTreeNode.Property{ .dma_ranges = value };
    } else if (std.mem.eql(u8, name_slice, "dma-coherent")) {
        prop = DeviceTreeNode.Property{ .dma_coherent = {} };
    } else if (std.mem.eql(u8, name_slice, "dma-noncoherent")) {
        prop = DeviceTreeNode.Property{ .dma_noncoherent = {} };
    } else if (std.mem.eql(u8, name_slice, "interrupts")) {
        prop = DeviceTreeNode.Property{ .interrupts = value };
    } else if (std.mem.eql(u8, name_slice, "interrupt-parent")) {
        prop = DeviceTreeNode.Property{ .interrupt_parent = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "interrupts-extended")) {
        prop = DeviceTreeNode.Property{ .interrupts_extended = .{ .buff = value } };
    } else if (std.mem.eql(u8, name_slice, "#interrupt-cells")) {
        prop = DeviceTreeNode.Property{ .interrupt_cells = std.mem.readInt(u32, value[0..4], .big) };
    } else if (std.mem.eql(u8, name_slice, "interrupt-controller")) {
        prop = DeviceTreeNode.Property{ .interrupt_controller = {} };
    } else if (std.mem.eql(u8, name_slice, "interrupt-map")) {
        prop = DeviceTreeNode.Property{ .interrupt_map = value };
    } else if (std.mem.eql(u8, name_slice, "interrupt-map-mask")) {
        prop = DeviceTreeNode.Property{ .interrupt_map_mask = value };
    } else if (std.mem.eql(u8, name_slice, "clock-frequency")) {
        const val = switch (value.len) {
            @sizeOf(u64) => std.mem.readInt(u64, value[0..8], .big),
            else => std.mem.readInt(u32, value[0..4], .big),
        };
        prop = DeviceTreeNode.Property{ .clock_frequency = val };
    } else if (std.mem.eql(u8, name_slice, "timebase-frequency")) {
        const val = switch (value.len) {
            @sizeOf(u64) => std.mem.readInt(u64, value[0..8], .big),
            else => std.mem.readInt(u32, value[0..4], .big),
        };
        prop = DeviceTreeNode.Property{ .timebase_frequency = val };
    } else {
        prop = DeviceTreeNode.Property{
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
    // freeing the memory is redundant

    while (continue_reading) {
        const tokenType: TokenType = readToken(ptr[ptr_idx]);
        ptr_idx += 1;
        switch (tokenType) {
            .begin_node => {
                const name = readBeginNode(ptr + ptr_idx);
                ptr_idx += std.math.divCeil(usize, name.len + 1, @sizeOf(u32)) catch unreachable;

                const child_handle: u32 = @intCast(dt.nodes.items.len);
                try dt.nodes.append(allocator, .{
                    .children = std.ArrayListUnmanaged(DeviceTreeNode.Child){},
                    .properties = std.ArrayListUnmanaged(DeviceTreeNode.Property){},
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
    var stream = std.io.fixedBufferStream(prop_buff[0..]);
    const writer = stream.writer();
    for (node.properties.items) |prop| {
        stream.reset();
        prop.print(handle, dt_root, writer) catch @panic("buffer too small");
        const str = stream.getWritten();
        std.log.info("{s}{s}", .{ space_buf[0..space_count], str });
    }

    for (node.children.items) |child| {
        printDeviceTree(child.name, dt_root, child.handle, depth + 1);
    }
}

fn initDriverFromDeviceTree(
    dt: *const DeviceTree,
    node: *const DeviceTreeNode,
    handle: u32,
) void {
    const compatible = node.getProperty(.compatible) orelse return;

    const node_name = blk: {
        if (node.parent_handle == no_parent) break :blk "/";
        const parent = dt.nodes.items[node.parent_handle];
        break :blk parent.getChildNameFromHandle(handle) orelse unreachable;
    };

    var it = compatible.iterator();
    while (it.next()) |node_comp| {
        inline for (config.modules) |mod| {
            if (!mod.enabled or mod.init_type != .driver) continue;
            for (mod.init_type.driver.compatible) |driver_comp| {
                if (!std.mem.eql(u8, driver_comp, node_comp)) continue;

                mod.module.initDriver(dt, handle) catch |err| {
                    std.log.err("failed to initialize {s}: {s}", .{ mod.name, @errorName(err) });
                };
                std.log.info("Module '{s}'({s}) initialized", .{ mod.name, node_name });

                return;
            }
        }
    }

    var compBuff: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(compBuff[0..]);
    const writer = stream.writer();
    compatible.print(writer) catch @panic("compatible string too long");
    const allCompString = stream.getWritten();

    std.log.warn(
        "Compatible driver not found for '{s}' compatible: '{s}'",
        .{ node_name, allCompString },
    );
}

pub fn initDriversFromDeviceTreeEarly(dt: *const DeviceTree) void {
    for (dt.nodes.items, 0..) |*node, handle| {
        if (node.getProperty(.interrupt_controller) == null) continue;
        initDriverFromDeviceTree(dt, node, @intCast(handle));
    }
}

pub fn initDriversFromDeviceTree(dt: *const DeviceTree) void {
    for (dt.nodes.items, 0..) |*node, handle| {
        if (node.getProperty(.interrupt_controller) != null) continue;
        initDriverFromDeviceTree(dt, node, @intCast(handle));
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
        .nodes = std.ArrayListUnmanaged(DeviceTreeNode){},
        .blob = blob[0 .. blob_size / 4],
        .phandle_table = std.AutoArrayHashMapUnmanaged(u32, u32){},
    };

    try dt.nodes.append(allocator, .{
        .children = std.ArrayListUnmanaged(DeviceTreeNode.Child){},
        .properties = std.ArrayListUnmanaged(DeviceTreeNode.Property){},
        .parent_handle = no_parent,
    });

    const root_node_read = try readNode(allocator, &dt, 0, ptr);
    _ = root_node_read;

    return dt;
}
