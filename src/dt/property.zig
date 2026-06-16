const std = @import("std");
const devicetree = @import("devicetree.zig");

const DeviceTree = devicetree.DeviceTree;
const DeviceTreeNode = devicetree.DeviceTreeNode;

inline fn readCells(buff: []const u8, idx: *u32, cells_per_val: u32) u128 {
    const val = switch (cells_per_val) {
        0 => 0,
        1 => std.mem.readInt(u32, @ptrCast(&buff[idx.*]), .big),
        2 => std.mem.readInt(u64, @ptrCast(&buff[idx.*]), .big),
        3 => std.mem.readInt(u96, @ptrCast(&buff[idx.*]), .big),
        4 => std.mem.readInt(u128, @ptrCast(&buff[idx.*]), .big),
        else => @panic("unsupported cell size"),
    };
    idx.* += cells_per_val * @sizeOf(u32);

    return val;
}

pub const PropertyType = enum {
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

pub const Property = union(PropertyType) {
    compatible: Compatible,
    model: []const u8,
    phandle: u32,
    status: []const u8,
    address_cells: u32,
    size_cells: u32,
    reg: Reg,
    virtual_reg: Reg,
    ranges: Range,
    dma_ranges: Range,
    dma_coherent: void,
    dma_noncoherent: void,
    interrupts: []const u8,
    interrupt_parent: u32,
    interrupts_extended: InterruptsExtended,
    interrupt_cells: u32,
    interrupt_controller: void,
    interrupt_map: InterruptMap,
    interrupt_map_mask: []const u8, // TODO
    clock_frequency: u64,
    timebase_frequency: u64,
    other: struct {
        name: []const u8,
        value: []const u8,
    },

    pub fn print(self: Property, handle: u32, dt: *const DeviceTree, writer: *std.Io.Writer) !void {
        switch (self) {
            .compatible => |compatible| {
                _ = try writer.print("compatible = 0x{x} ", .{@intFromPtr(compatible.buff.ptr)});
                try compatible.print(writer);
            },
            .model => |val| {
                try writer.print("model = {s}", .{val});
            },
            .phandle => |val| {
                try writer.print("phandle = {}", .{val});
            },
            .status => |val| {
                try writer.print("status = {s}", .{val});
            },
            .address_cells => |val| {
                try writer.print("address_cells = {}", .{val});
            },
            .size_cells => |val| {
                try writer.print("size_cells = {}", .{val});
            },
            .interrupt_map => |val| {
                const node = dt.nodes.items[handle];
                const child_address_cells = node.getAddressCell();
                const child_interrupt_cells = node.getProperty(.interrupt_cells) orelse unreachable;

                _ = try writer.write("interrupt_map = ");
                try val.print(writer, dt, child_address_cells, child_interrupt_cells);
            },
            .ranges => |val| {
                const node = dt.nodes.items[handle];
                const parent_address_cells = node.getAddressCellFromParent(dt);
                const child_address_cells = node.getAddressCell();
                const child_size_cells = node.getSizeCell();

                _ = try writer.write("ranges = ");
                try val.print(writer, parent_address_cells, child_address_cells, child_size_cells);
            },
            .dma_ranges => |val| {
                const node = dt.nodes.items[handle];
                const parent_address_cells = node.getAddressCellFromParent(dt);
                const child_address_cells = node.getAddressCell();
                const child_size_cells = node.getSizeCell();

                _ = try writer.write("dma_ranges = ");
                try val.print(writer, parent_address_cells, child_address_cells, child_size_cells);
            },
            .reg => |val| {
                const node = dt.nodes.items[handle];
                const address_cells = node.getAddressCellFromParent(dt);
                const size_cells = node.getSizeCellFromParent(dt);

                _ = try writer.write("reg = ");
                try val.print(writer, address_cells, size_cells);
            },
            .virtual_reg => |val| {
                const node = dt.nodes.items[handle];
                const address_cells = node.getAddressCellFromParent(dt);
                const size_cells = node.getSizeCellFromParent(dt);

                _ = try writer.write("virtual_reg = ");
                try val.print(writer, address_cells, size_cells);
            },
            .interrupts => |val| {
                _ = try writer.print("interrupts = {any}", .{val});
            },
            .interrupts_extended => {
                _ = try writer.write("interrupts_extended = ");
            },
            .interrupt_parent => |val| {
                const parent_handle = dt.phandle_table.get(val) orelse
                    return error.InvalidDeviceTree;
                try writer.print("interrupt_parent = <&{s}>", .{dt.getNodeName(parent_handle)});
            },
            .interrupt_cells => |val| {
                try writer.print("interrupt_cells = {}", .{val});
            },
            .interrupt_controller => {
                try writer.print("interrupt_controller;", .{});
            },
            .clock_frequency => |val| {
                try writer.print("clock_frequency = {}", .{val});
            },
            .timebase_frequency => |val| {
                try writer.print("timebase_frequency = {}", .{val});
            },
            .other => |val| {
                try writer.print("{s} = {any}", .{ val.name, val.value });
            },
            else => {
                // TODO:
                try writer.print("{any}", .{self});
            },
        }
    }
};

pub const InterruptsExtended = struct {
    buff: []const u8,

    pub fn iterator(
        self: InterruptsExtended,
        dt: *const DeviceTree,
    ) Iterator {
        return Iterator{
            .buff = self.buff,
            .idx = 0,
            .dt = dt,
        };
    }

    pub fn print(
        self: InterruptsExtended,
        dt: *const DeviceTree,
        writer: *std.Io.Writer,
    ) !void {
        var it = self.iterator(dt);
        var first = true;
        while (it.next()) |int| {
            if (first) {
                first = false;
            } else {
                _ = try writer.writeByte(' ');
            }

            const name = dt.getNodeName(int.handle);
            try writer.print("<&{s} 0x{x}>", .{ name, int.interrupt_specifier });
        }
    }

    pub const Iterator = struct {
        buff: []const u8,
        idx: u32,
        dt: *const DeviceTree,

        pub fn next(self: *Iterator) ?Interrupt {
            if (self.idx == self.buff.len) return null;

            const phandle: u32 = @intCast(readCells(self.buff, &self.idx, 1));
            const int_cont_handle = self.dt.phandle_table.get(phandle) orelse
                @panic("Invalid phandle");
            const int_cont_node = self.dt.nodes.items[int_cont_handle];
            const interrupt_cells = int_cont_node.getProperty(.interrupt_cells) orelse
                @panic("Interrupt controller does not have .interrupt_cells");

            return Interrupt{
                .handle = int_cont_handle,
                .interrupt_specifier = @intCast(readCells(
                    self.buff,
                    &self.idx,
                    interrupt_cells,
                )),
            };
        }
    };

    const Interrupt = struct {
        handle: u32,
        interrupt_specifier: u64,
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

    pub fn print(self: Compatible, writer: *std.Io.Writer) !void {
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

    pub fn print(
        self: Reg,
        writer: *std.Io.Writer,
        address_cells: u32,
        size_cells: u32,
    ) !void {
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
                try writer.print("0x{x}", .{reg.address});
            } else {
                try writer.print("0x{x} 0x{x}", .{ reg.address, reg.size });
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

        pub fn next(self: *Iterator) ?RegEntry {
            if (self.idx == self.buff.len) return null;

            return .{
                .address = readCells(self.buff, &self.idx, self.address_cells),
                .size = readCells(self.buff, &self.idx, self.size_cells),
            };
        }
    };

    const RegEntry = struct {
        address: u128,
        size: u128,
    };
};

pub const Range = struct {
    buff: []const u8,

    pub fn print(
        self: Range,
        writer: *std.Io.Writer,
        parent_address_cells: u32,
        child_address_cells: u32,
        child_size_cells: u32,
    ) !void {
        var it = try self.iterator(parent_address_cells, child_address_cells, child_size_cells);
        var first = true;
        _ = try writer.writeByte('<');
        while (it.next()) |range| {
            if (first) {
                first = false;
            } else {
                _ = try writer.writeByte(' ');
            }

            try writer.print("0x{x} 0x{x} 0x{x}", .{
                range.child_address,
                range.parent_address,
                range.size,
            });
        }
        _ = try writer.writeByte('>');
    }

    pub fn iterator(
        self: Range,
        parent_address_cells: u32,
        child_address_cells: u32,
        child_size_cells: u32,
    ) !Iterator {
        const entry_size = parent_address_cells + child_address_cells + child_size_cells;
        const rem = std.math.mod(usize, self.buff.len, entry_size) catch
            return error.InvalidCellCounts;
        if (rem != 0)
            return error.InvalidCellCounts;

        return .{
            .buff = self.buff,
            .parent_address_cells = parent_address_cells,
            .child_address_cells = child_address_cells,
            .child_size_cells = child_size_cells,
            .idx = 0,
        };
    }

    pub const Iterator = struct {
        buff: []const u8,
        parent_address_cells: u32,
        child_address_cells: u32,
        child_size_cells: u32,
        idx: u32,

        pub fn next(self: *Iterator) ?RangeEntry {
            if (self.idx == self.buff.len) return null;

            return .{
                .child_address = readCells(self.buff, &self.idx, self.child_address_cells),
                .parent_address = readCells(self.buff, &self.idx, self.parent_address_cells),
                .size = readCells(self.buff, &self.idx, self.child_size_cells),
            };
        }
    };

    // TODO: decide whether there is a better way to return ranges
    const RangeEntry = struct {
        child_address: u128,
        parent_address: u128,
        size: u128,
    };
};

pub const InterruptMap = struct {
    buff: []const u8,

    pub fn print(
        self: InterruptMap,
        writer: *std.Io.Writer,
        dt: *const devicetree.DeviceTree,
        child_address_cells: u32,
        child_interrupt_cells: u32,
    ) !void {
        var it = self.iterator(child_address_cells, child_interrupt_cells);
        var first = true;
        _ = try writer.writeByte('<');
        while (it.next(dt)) |mapping| {
            if (first) {
                first = false;
            } else {
                _ = try writer.writeByte(' ');
            }

            const parent = dt.nodes.items[mapping.interrupt_parent_handle];
            const grand_parent = dt.nodes.items[parent.parent_handle];
            const parent_name = grand_parent.getChildNameFromHandle(
                mapping.interrupt_parent_handle,
            ) orelse unreachable;

            try writer.print("0x{x} 0x{x} &{s} 0x{x} 0x{x}", .{
                mapping.child_address,
                mapping.child_interrupt_specifier,
                parent_name,
                mapping.parent_address,
                mapping.parent_interrupt_specifier,
            });
        }
        _ = try writer.writeByte('>');
    }

    pub fn iterator(
        self: InterruptMap,
        child_address_cells: u32,
        child_interrupt_cells: u32,
    ) Iterator {
        return .{
            .buff = self.buff,
            .child_address_cells = child_address_cells,
            .child_interrupt_cells = child_interrupt_cells,
            .idx = 0,
        };
    }

    pub const Iterator = struct {
        buff: []const u8,
        child_address_cells: u32,
        child_interrupt_cells: u32,
        idx: u32,

        pub fn next(self: *Iterator, dt: *const devicetree.DeviceTree) ?Entry {
            if (self.idx == self.buff.len) return null;

            const child_address = readCells(self.buff, &self.idx, self.child_address_cells);
            const child_int_specifier = readCells(self.buff, &self.idx, self.child_interrupt_cells);
            const int_phandle: u32 = @intCast(readCells(self.buff, &self.idx, 1));
            const int_parent_handle = dt.phandle_table.get(int_phandle) orelse @panic("TODO");

            const parent_node = dt.nodes.items[int_parent_handle];

            const parent_address_cells = parent_node.getAddressCell();
            const parent_int_cells = parent_node.getProperty(.interrupt_cells) orelse @panic("TODO: parent interrupt cells");

            const parent_address = readCells(self.buff, &self.idx, parent_address_cells);
            const parent_interrupt_specifier = readCells(self.buff, &self.idx, parent_int_cells);

            return .{
                .child_address = child_address,
                .child_interrupt_specifier = child_int_specifier,
                .interrupt_parent_handle = int_parent_handle,
                .parent_address = parent_address,
                .parent_interrupt_specifier = parent_interrupt_specifier,
            };
        }
    };

    pub const Entry = struct {
        child_address: u128,
        child_interrupt_specifier: u128,
        interrupt_parent_handle: u32,
        parent_address: u128,
        parent_interrupt_specifier: u128,
    };
};
