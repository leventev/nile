const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const devicetree = root.devicetree;
const arch = @import("../arch/arch.zig");
const Process = @import("../Process.zig");
const buddy_allocator = @import("buddy_allocator.zig");

const log = std.log.scoped(.mm);

const bigToNative = std.mem.bigToNative;

// these addresses of these symbols can be used to
// calculate the sizes of the loaded sections
// TODO: maybe put these definitions in another file
extern const __kernel_start: u8;
extern const __kernel_end: u8;
extern const __text_start: u8;
extern const __text_end: u8;
extern const __data_start: u8;
extern const __data_end: u8;
extern const __rodata_start: u8;
extern const __rodata_end: u8;
extern const __bss_start: u8;
extern const __bss_end: u8;

pub const frame_size = arch.page_size;

pub const PageTable = arch.PageTable;
pub const VirtualAddress = packed struct(usize) {
    address: usize,

    pub fn fromInt(addr: usize) VirtualAddress {
        return @bitCast(addr);
    }

    pub fn asInt(self: VirtualAddress) usize {
        return @bitCast(self);
    }

    pub fn add(self: VirtualAddress, offset: usize) VirtualAddress {
        return fromInt(self.asInt() + offset);
    }

    pub fn asPtr(self: VirtualAddress, comptime T: type) T {
        if (@typeInfo(T) != .pointer) @compileError("not a pointer");
        return @ptrFromInt(self.asInt());
    }

    pub fn isPageAligned(self: VirtualAddress) bool {
        return self.address % arch.page_size == 0;
    }
};

pub const PhysicalAddress = packed struct(usize) {
    address: u64,

    pub fn fromInt(addr: usize) PhysicalAddress {
        return @bitCast(addr);
    }

    pub fn asInt(self: PhysicalAddress) u64 {
        return @bitCast(self);
    }

    pub fn add(self: PhysicalAddress, offset: usize) PhysicalAddress {
        return fromInt(self.asInt() + offset);
    }

    pub fn asPtr(self: PhysicalAddress, comptime T: type) T {
        if (@typeInfo(T) != .pointer) @compileError("not a pointer");
        return @ptrFromInt(self.asInt());
    }

    pub fn isPageAligned(self: PhysicalAddress) bool {
        return self.address % arch.page_size == 0;
    }
};

/// Returns the start of the higher half memory address space for a given useful bit count.
/// For example in Sv39 there are 39 useful bits.
/// The address space is split in half to a lower half and higher half address space.
/// An N bit address space has 2^N valid addresses.
/// The lower half is 0 <=> 2^(N-1) - 1.
/// The higher half is 2^64-2^(N-1) <=> 2^64 - 1.
/// Thus the higher half address has the most significant 64-N+1 bits set, the rest clear.
fn higherHalfAddress(used_bits: usize) VirtualAddress {
    const final = std.math.shl(usize, std.math.maxInt(usize), used_bits - 1);
    return .fromInt(final);
}

const sv39_higher_half_start = higherHalfAddress(39);

pub const UserAddress = struct {
    address: VirtualAddress,

    pub fn fromInt(addr: usize) UserAddress {
        return .{ .address = VirtualAddress.fromInt(addr) };
    }

    pub fn asPtr(self: UserAddress, comptime T: type) T {
        return self.address.asPtr(T);
    }

    pub fn add(self: UserAddress, offset: usize) UserAddress {
        return .{ .address = self.address.add(offset) };
    }

    pub fn isValid(self: UserAddress) bool {
        return self.address.asInt() < sv39_higher_half_start.asInt();
    }
};

// TODO: move all device tree specific code to devicetree.zig
pub const MemoryRegion = struct {
    start: PhysicalAddress,
    size: u64,

    const Self = @This();

    fn end(self: Self) PhysicalAddress {
        return self.start.add(self.size);
    }

    fn intersects(self: Self, other: MemoryRegion) bool {
        const other_after = other.start.asInt() >= self.end().asInt();
        const other_before = other.end().asInt() <= self.start.asInt();
        return !(other_after or other_before);
    }
};

pub const PhysicalMemoryRegion = struct {
    range: MemoryRegion,
};

const ReservedMemoryRegion = struct {
    range: MemoryRegion,
    name: []const u8,
    no_map: bool,
    reusable: bool,
    system: bool,
    // TODO: support dynamic reservations too
};

fn readMemoryPair(buff: []const u8, idx: usize, entrySize: usize) MemoryRegion {
    const entry_base = idx * entrySize;
    const entry = buff[entry_base .. entry_base + entrySize];

    const addr = std.mem.readInt(u64, entry[0..8], .big);
    const size = std.mem.readInt(u64, entry[8..16], .big);

    return MemoryRegion{ .start = .fromInt(addr), .size = size };
}

fn parseMemoryRegions(
    allocator: std.mem.Allocator,
    dt: *const devicetree.DeviceTree,
    dt_root: *const devicetree.DeviceTreeNode,
) !std.ArrayListUnmanaged(PhysicalMemoryRegion) {
    var regions = std.ArrayList(PhysicalMemoryRegion).empty;

    for (dt_root.children.items) |child| {
        if (!std.mem.startsWith(u8, child.name, "memory"))
            continue;

        const node = dt.nodes.items[child.handle];

        const reg = node.getProperty(.reg) orelse return error.InvalidDeviceTree;
        const address_cells = node.getAddressCellFromParent(dt);
        const size_cells = node.getSizeCellFromParent(dt);

        if (address_cells > 2 or size_cells > 2)
            @panic("address-cells and size-cells must not be bigger than 2");

        var it = reg.iterator(address_cells, size_cells) catch return error.InvalidDeviceTree;

        while (it.next()) |entry| {
            try regions.append(allocator, PhysicalMemoryRegion{
                .range = .{
                    .start = .fromInt(@intCast(entry.address)),
                    .size = @intCast(entry.size),
                },
            });
        }
    }

    return regions;
}

fn parseReservedMemoryRegions(
    allocator: std.mem.Allocator,
    dt: *const devicetree.DeviceTree,
    dt_root: *const devicetree.DeviceTreeNode,
) !std.ArrayListUnmanaged(ReservedMemoryRegion) {
    const reserved_memory = dt.getChild(dt_root, "reserved-memory") orelse return error.InvalidDeviceTree;

    var regions = std.ArrayList(ReservedMemoryRegion).empty;

    for (reserved_memory.children.items) |region| {
        const node = dt.nodes.items[region.handle];

        const no_map = node.getPropertyOther("no-map") != null;
        const reusable = node.getPropertyOther("reusable") != null;

        const reg = node.getProperty(.reg) orelse continue;
        const address_cells = node.getAddressCellFromParent(dt);
        const size_cells = node.getSizeCellFromParent(dt);

        if (address_cells > 2 or size_cells > 2)
            @panic("address-cells and size-cells must not be bigger than 2");

        var it = reg.iterator(address_cells, size_cells) catch return error.InvalidDeviceTree;

        while (it.next()) |entry| {
            try regions.append(allocator, ReservedMemoryRegion{
                .range = .{
                    .start = .fromInt(@intCast(entry.address)),
                    .size = @intCast(entry.size),
                },
                .name = region.name,
                .no_map = no_map,
                .reusable = reusable,
                .system = false,
            });
        }
    }

    return regions;
}

const minimum_region_size = 8 * 4096;

fn processRegion(
    allocator: std.mem.Allocator,
    regs: *std.ArrayList(MemoryRegion),
    region: PhysicalMemoryRegion,
    reserved_regions: []const ReservedMemoryRegion,
) !void {
    std.debug.assert(region.range.start.isPageAligned());
    std.debug.assert(region.range.size % arch.page_size == 0);

    var range = region.range;

    for (reserved_regions) |resv| {
        std.debug.assert(resv.range.start.isPageAligned());
        std.debug.assert(resv.range.size % arch.page_size == 0);

        if (!range.intersects(resv.range))
            continue;

        const resv_range = resv.range;

        const end = range.end();
        const resv_end = resv_range.end();

        // the reserved region starts before or at the same address as the physical region
        if (resv_range.start.asInt() <= region.range.start.asInt()) {
            // cut off the interescting part at the beginning of the region
            range.start = resv_end;
            range.size = end.asInt() - range.start.asInt();

            continue;
        }

        // the reserved region ends after or at the same address as the physical region
        if (resv_end.asInt() >= end.asInt()) {
            // cut off the interescting part at the end of the region
            range.size = resv_range.start.asInt() - range.start.asInt();

            continue;
        }

        // the reserved region is inside the physical region
        range.size = resv_range.start.asInt() - range.start.asInt();

        // do the same process for the region on the right side of the reserved region
        const other_region = PhysicalMemoryRegion{
            .range = MemoryRegion{
                .start = resv_end,
                .size = end.asInt() - resv_end.asInt(),
            },
        };

        try processRegion(allocator, regs, other_region, reserved_regions);
    }

    if (range.size >= minimum_region_size)
        try regs.append(allocator, range);
}

fn getUsableRegions(
    allocator: std.mem.Allocator,
    physical_regions: []const PhysicalMemoryRegion,
    reserved_regions: []const ReservedMemoryRegion,
) !std.ArrayList(MemoryRegion) {
    var regions = std.ArrayList(MemoryRegion).empty;

    for (physical_regions) |phys| {
        try processRegion(allocator, &regions, phys, reserved_regions);
    }

    return regions;
}

fn addKernelReservedMemory(
    allocator: std.mem.Allocator,
    reserved_regions: *std.ArrayListUnmanaged(ReservedMemoryRegion),
) !void {
    // we can(have to) align forward the end address of the segments because the next segment should be at the next possible 4K aligned address
    const text_start = @intFromPtr(&__text_start);
    const text_end = @intFromPtr(&__text_end);
    const text_size = text_end - text_start;

    const data_start = @intFromPtr(&__data_start);
    const data_end = @intFromPtr(&__data_end);
    const data_size = data_end - data_start;

    const rodata_start = @intFromPtr(&__rodata_start);
    const rodata_end = @intFromPtr(&__rodata_end);
    const rodata_size = rodata_end - rodata_start;

    const bss_start = @intFromPtr(&__bss_start);
    const bss_end = @intFromPtr(&__bss_end);
    const bss_size = bss_end - bss_start;

    const kernel_start = @intFromPtr(&__kernel_start);
    // we align forward so that the size of the region is divisible by 4K
    const kernel_end = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), 4096);
    const kernel_size = kernel_end - kernel_start;

    log.info("Kernel code: {} KiB, rodata: {} KiB, data: {} KiB, bss: {} KiB", .{
        text_size / 1024,
        rodata_size / 1024,
        data_size / 1024,
        bss_size / 1024,
    });

    try reserved_regions.append(allocator, ReservedMemoryRegion{
        .name = "kernel",
        .no_map = true,
        .reusable = false,
        .system = true,
        .range = MemoryRegion{
            .start = .fromInt(kernel_start - arch.kernel_virtual_offset),
            .size = kernel_size,
        },
    });
}

fn addDeviceTreeReservedMemory(
    allocator: std.mem.Allocator,
    reserved_regions: *std.ArrayListUnmanaged(ReservedMemoryRegion),
    dt: *const devicetree.DeviceTree,
) !void {
    // we need to reserve memory for the DT itself
    const dt_start = std.mem.alignBackward(u64, @intFromPtr(dt.blob.ptr), 4096);
    const dt_end = std.mem.alignForward(u64, @intCast(@intFromPtr(dt.blob.ptr) + dt.blob.len), 4096);

    const dt_region = ReservedMemoryRegion{
        .name = "device-tree",
        .no_map = true,
        .reusable = false,
        .system = false,
        .range = MemoryRegion{
            .start = .fromInt(dt_start - arch.kernel_virtual_offset),
            .size = dt_end - dt_start,
        },
    };
    try reserved_regions.append(allocator, dt_region);
}

fn printPhysicalRegions(physical_regions: []const PhysicalMemoryRegion) void {
    log.info("Physical memory regions:", .{});
    for (physical_regions) |reg| {
        const range = reg.range;
        const sizeInKiB = range.size / 1024;
        log.info(
            "    [0x{x:0>16}-0x{x:0>16}] ({} KiB)",
            .{ range.start.asInt(), range.end().asInt() - 1, sizeInKiB },
        );
    }
}

fn printReservedRegions(reserved_regions: []const ReservedMemoryRegion) void {
    log.info("Reserved memory regions:", .{});
    for (reserved_regions) |reg| {
        const range = reg.range;
        const size_in_kib = range.size / 1024;
        if (reg.system) {
            log.info("    [0x{x:0>16}-0x{x:0>16}] <{s}> ({} KiB) system", .{
                range.start.asInt(),
                range.end().asInt() - 1,
                reg.name,
                size_in_kib,
            });
        } else {
            const no_map_string = if (reg.no_map) "no-map" else "map";
            const reusable_string = if (reg.reusable) "reusable" else "non-reusable";
            log.info("    [0x{x:0>16}-0x{x:0>16}] <{s}> ({} KiB) {s} {s}", .{
                range.start.asInt(),
                range.end().asInt() - 1,
                reg.name,
                size_in_kib,
                no_map_string,
                reusable_string,
            });
        }
    }
}

fn printUsableRegions(regions: []const MemoryRegion) void {
    log.info("Usable memory regions:", .{});
    for (regions) |reg| {
        const size_in_kib = reg.size / 1024;
        log.info(
            "    [0x{x:0>16}-0x{x:0>16}] ({} KiB)",
            .{ reg.start.asInt(), reg.end().asInt() - 1, size_in_kib },
        );
    }
}

pub fn getFrameRegions(
    allocator: std.mem.Allocator,
    dt: *const devicetree.DeviceTree,
) ![]const MemoryRegion {
    var phyiscal_regions = try parseMemoryRegions(allocator, dt, dt.root());
    defer phyiscal_regions.deinit(allocator);

    var reserved_regions = try parseReservedMemoryRegions(allocator, dt, dt.root());
    defer reserved_regions.deinit(allocator);

    try addDeviceTreeReservedMemory(allocator, &reserved_regions, dt);
    try addKernelReservedMemory(allocator, &reserved_regions);

    printPhysicalRegions(phyiscal_regions.items);
    printReservedRegions(reserved_regions.items);

    var usable_regions = try getUsableRegions(
        allocator,
        phyiscal_regions.items,
        reserved_regions.items,
    );

    printUsableRegions(usable_regions.items);

    return usable_regions.toOwnedSlice(allocator);
}

const hhdm_start = if (builtin.is_test) 0 else 0xffffffc000000000;

pub fn physicalToVirtualAddress(phys: PhysicalAddress) VirtualAddress {
    // TODO: check whether the provided physical address is mapped in the HHDM region
    return VirtualAddress.fromInt(hhdm_start + phys.asInt());
}

pub fn virtualToPhysicalAddress(virt: VirtualAddress) PhysicalAddress {
    // TODO: check whether the provided virtual address is in the HHDM region
    return PhysicalAddress.fromInt(virt.asInt() - hhdm_start);
}

pub fn clonePageTable(page_table: arch.PageTable) !arch.PageTable {
    const new_page_table_phys = try buddy_allocator.allocBlock(0);
    const new_page_table_virt = physicalToVirtualAddress(new_page_table_phys);
    const new_page_table = PageTable.fromVirtualAddress(new_page_table_virt);

    arch.copyPageTable(page_table, new_page_table);

    return new_page_table;
}

pub fn mapRegion(root_page_table: arch.PageTable, addr: VirtualAddress, size: usize, flags: Process.MappedRegion.Flags) void {
    // TODO: errors
    if (addr % arch.page_size != 0) @panic("unaligned address");
    if (addr % size != 0) @panic("size != k * page_size");

    // TODO: make this more efficient, map larger pages
    arch.mapRegion(root_page_table, addr, size, flags);
}
