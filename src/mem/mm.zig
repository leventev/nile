const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const devicetree = root.devicetree;
const arch = @import("../arch/arch.zig");
const Process = @import("../Process.zig");
const buddy_allocator = @import("buddy_allocator.zig");
const scheduler = @import("../scheduler.zig");
const processes = @import("../processes.zig");
const vfs = @import("../vfs.zig");
const page_descriptors = @import("page_descriptors.zig");

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
    int: usize,

    pub fn fromInt(address: usize) VirtualAddress {
        return .{ .int = address };
    }

    pub fn add(self: VirtualAddress, offset: usize) VirtualAddress {
        return .{ .int = self.int +% offset };
    }

    pub fn asPtr(self: VirtualAddress, comptime T: type) T {
        if (@typeInfo(T) != .pointer) @compileError("not a pointer");
        return @ptrFromInt(self.int);
    }

    pub fn isPageAligned(self: VirtualAddress) bool {
        return self.int % arch.page_size == 0;
    }

    pub fn isHigherHalf(self: VirtualAddress) bool {
        return self.int >= arch.kernel_addresses.higher_half;
    }
};

pub const PhysicalAddress = packed struct(usize) {
    int: usize,

    pub fn fromInt(addr: usize) PhysicalAddress {
        return .{ .int = addr };
    }

    pub fn add(self: PhysicalAddress, offset: usize) PhysicalAddress {
        return fromInt(self.int +% offset);
    }

    pub fn isPageAligned(self: PhysicalAddress) bool {
        return self.int % arch.page_size == 0;
    }
};

/// Returns the start of the higher half memory address space for a given useful bit count.
/// For example in Sv39 there are 39 useful bits.
/// The address space is split in half to a lower half and higher half address space.
/// An N bit address space has 2^N valid addresses.
/// The lower half is 0 <=> 2^(N-1) - 1.
/// The higher half is 2^64-2^(N-1) <=> 2^64 - 1.
/// Thus the higher half address has the most significant 64-N+1 bits set, the rest clear.
pub fn calculateHigherHalfAddress(used_bits: usize) VirtualAddress {
    const final = std.math.shl(usize, std.math.maxInt(usize), used_bits - 1);
    return .fromInt(final);
}

pub const UserAddress = struct {
    int: usize,

    pub fn fromInt(address: usize) ?UserAddress {
        return fromVirtual(.fromInt(address));
    }

    pub fn fromVirtual(address: VirtualAddress) ?UserAddress {
        return if (address.isHigherHalf()) null else .{ .int = address.int };
    }

    pub fn asPtr(self: UserAddress, comptime T: type) T {
        if (@typeInfo(T) != .pointer) @compileError("not a pointer");
        return @ptrFromInt(self.int);
    }

    pub fn add(self: UserAddress, offset: usize) ?UserAddress {
        return fromInt(self.int +% offset);
    }

    pub fn slice(self: UserAddress, size: usize) ?[]u8 {
        std.debug.assert(size > 0);

        // last byte accessed
        const end = self.add(size - 1) orelse return null;

        // on overflow
        if (end.int < self.int)
            return null;

        return self.asPtr([*]u8)[0..size];
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
        // TODO: this is probably not correct?
        const other_after = other.start.int >= self.end().int;
        const other_before = other.end().int <= self.start.int;
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
        if (resv_range.start.int <= region.range.start.int) {
            // cut off the interescting part at the beginning of the region
            range.start = resv_end;
            range.size = end.int - range.start.int;

            continue;
        }

        // the reserved region ends after or at the same address as the physical region
        if (resv_end.int >= end.int) {
            // cut off the interescting part at the end of the region
            range.size = resv_range.start.int - range.start.int;

            continue;
        }

        // the reserved region is inside the physical region
        range.size = resv_range.start.int - range.start.int;

        // do the same process for the region on the right side of the reserved region
        const other_region = PhysicalMemoryRegion{
            .range = MemoryRegion{
                .start = resv_end,
                .size = end.int - resv_end.int,
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
            .start = .fromInt(kernel_start - arch.kernel_addresses.kernel_virtual_offset),
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
            .start = .fromInt(dt_start - arch.kernel_addresses.kernel_virtual_offset),
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
            .{ range.start.int, range.end().int - 1, sizeInKiB },
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
                range.start.int,
                range.end().int - 1,
                reg.name,
                size_in_kib,
            });
        } else {
            const no_map_string = if (reg.no_map) "no-map" else "map";
            const reusable_string = if (reg.reusable) "reusable" else "non-reusable";
            log.info("    [0x{x:0>16}-0x{x:0>16}] <{s}> ({} KiB) {s} {s}", .{
                range.start.int,
                range.end().int - 1,
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
            .{ reg.start.int, reg.end().int - 1, size_in_kib },
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

pub fn physicalToVirtual(phys: PhysicalAddress) VirtualAddress {
    // TODO: check whether the provided physical address is mapped in the HHDM region
    return VirtualAddress.fromInt(hhdm_start + phys.int);
}

pub fn virtualToPhysical(virt: VirtualAddress) PhysicalAddress {
    // TODO: check whether the provided virtual address is in the HHDM region
    return PhysicalAddress.fromInt(virt.int - hhdm_start);
}

/// Allocates a new page table and shallow copies an existing page table's entries to it.
pub fn clonePageTable(page_table: arch.PageTable, only_higher_half: bool) error{OutOfMemory}!arch.PageTable {
    const new_page_table_phys = buddy_allocator.allocBlock(0) catch |err| switch (err) {
        error.InvalidOrder => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const new_page_table_virt = physicalToVirtual(new_page_table_phys);
    const new_page_table = PageTable.fromVirtualAddress(new_page_table_virt);

    arch.copyPageTable(page_table, new_page_table, only_higher_half);

    return new_page_table;
}

pub fn mapRegion(root_page_table: arch.PageTable, addr: VirtualAddress, size: usize, flags: Process.MappedRegion.Flags) void {
    // TODO: errors
    if (addr % arch.page_size != 0) @panic("unaligned address");
    if (addr % size != 0) @panic("size != k * page_size");

    // TODO: make this more efficient, map larger pages
    arch.mapRegion(root_page_table, addr, size, flags);
}

pub const PagefaultType = enum {
    read,
    write,
    instruction,
};

pub fn handlePageFault(address: VirtualAddress, page_fault_type: PagefaultType) bool {
    const current_thread = scheduler.getCurrentThread();
    demand_paging: {
        if (current_thread.purpose != .general) break :demand_paging;
        const general_thread = &current_thread.purpose.general;

        const user_address = UserAddress.fromVirtual(address) orelse {
            // TODO: signal
            processes.killCurrentProcess(-123);
            return false;
        };

        const process = general_thread.owner_process;
        var next_ptr = &process.mapped_regions;
        while (next_ptr.*) |region| : (next_ptr = &region.next) {
            if (!region.contains(user_address))
                continue;

            const invalid_privilige = switch (page_fault_type) {
                .instruction => !region.flags.execute,
                .read => !region.flags.read,
                .write => !region.flags.write,
            };

            if (invalid_privilige) {
                processes.killCurrentProcess(-123);
                return false;
            }

            // TODO: i should actually test whether this works how it's intended, like bss being
            // all zeros.
            var zeroed_size: usize = 0;
            const frame = if (region.backing) |backing| blk: {
                const region_offset = user_address.int - region.address.int;

                const region_page_idx = region_offset / arch.page_size;
                const backing_page_idx = backing.size / arch.page_size;

                // if the region is writable we make a copy to not change the contents of the
                // original, otherwise it is fine to use the same page
                const should_alloc = region_page_idx >= backing_page_idx or region.flags.write;

                const file_offset = backing.offset + region_offset;
                const page_idx = file_offset / arch.page_size;
                const regular = backing.file.dir_ent.regular();
                const backing_virt = regular.page_cache.getPage(page_idx, true) catch
                    @panic("TODO: read from block device");

                if (should_alloc) {
                    const backing_page: []const u8 = backing_virt.asPtr([*]u8)[0..arch.page_size];

                    const new_phys = buddy_allocator.allocBlock(0) catch @panic("TODO");
                    const new_virt = physicalToVirtual(new_phys);
                    const new_page: []u8 = new_virt.asPtr([*]u8)[0..arch.page_size];

                    @memcpy(new_page, backing_page);

                    const remaining_file_size = region.size - backing.size;
                    zeroed_size = arch.page_size - @min(remaining_file_size, arch.page_size);
                    break :blk new_phys;
                } else {
                    const phys = virtualToPhysical(backing_virt);
                    const page_descriptor = page_descriptors.getDescriptor(phys);
                    _ = page_descriptor.reference_count.fetchAdd(1, .monotonic);

                    break :blk phys;
                }
            } else blk: {
                zeroed_size = arch.page_size;
                break :blk buddy_allocator.allocBlock(0) catch @panic("TODO");
            };

            var frames = [1]PhysicalAddress{frame};

            arch.mapRegion(
                process.root_page_table,
                user_address.int / arch.page_size,
                1,
                region.flags,
                &frames,
            ) catch @panic("TODO");

            const buff = physicalToVirtual(frame).asPtr([*]u8)[0..zeroed_size];
            @memset(buff, 0);

            return false;
        }
    }

    return true;
}
