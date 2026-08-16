const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const devicetree = root.devicetree;
const arch = @import("../arch/arch.zig");
const Process = @import("../Process.zig");
const buddy_allocator = @import("buddy_allocator.zig");
const slab_allocator = @import("slab_allocator.zig");
const scheduler = @import("../scheduler.zig");
const processes = @import("../processes.zig");
const vfs = @import("../vfs.zig");
const sync = @import("../sync.zig");

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
pub const PhysicalMemoryRegion = struct {
    frame_number: usize,
    frame_count: usize,

    fn end(self: PhysicalMemoryRegion) usize {
        return self.frame_number + self.frame_count;
    }

    fn intersects(self: PhysicalMemoryRegion, other: PhysicalMemoryRegion) bool {
        const other_after = other.frame_number >= self.end();
        const other_before = other.end() <= self.frame_number;
        return !(other_after or other_before);
    }
};

const ReservedMemoryRegion = struct {
    range: PhysicalMemoryRegion,
    name: []const u8,
    no_map: bool,
    reusable: bool,
    system: bool,
    // TODO: support dynamic reservations too
};

// TODO: move to devicetree
fn readMemoryPair(buff: []const u8, idx: usize, entrySize: usize) PhysicalMemoryRegion {
    const entry_base = idx * entrySize;
    const entry = buff[entry_base .. entry_base + entrySize];

    const addr = std.mem.readInt(u64, entry[0..8], .big);
    const size = std.mem.readInt(u64, entry[8..16], .big);

    return PhysicalMemoryRegion{ .start = .fromInt(addr), .size = size };
}

// TODO: move to devicetree
fn parseMemoryRegions(
    gpa: std.mem.Allocator,
    dt: *const devicetree.DeviceTree,
    dt_root: *const devicetree.DeviceTreeNode,
) error{ OutOfMemory, InvalidDeviceTree }![]PhysicalMemoryRegion {
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
            std.debug.assert(entry.address % arch.page_size == 0);
            std.debug.assert(entry.size % arch.page_size == 0);
            try regions.append(gpa, PhysicalMemoryRegion{
                .frame_number = @intCast(entry.address / arch.page_size),
                .frame_count = @intCast(entry.size / arch.page_size),
            });
        }
    }

    return regions.toOwnedSlice(gpa);
}

// TODO: move to devicetree
fn parseReservedMemoryRegions(
    gpa: std.mem.Allocator,
    dt: *const devicetree.DeviceTree,
    dt_root: *const devicetree.DeviceTreeNode,
) error{ OutOfMemory, InvalidDeviceTree }!std.ArrayList(ReservedMemoryRegion) {
    const reserved_memory = dt.getChild(dt_root, "reserved-memory") orelse
        return error.InvalidDeviceTree;

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
            std.debug.assert(entry.address % arch.page_size == 0);
            std.debug.assert(entry.size % arch.page_size == 0);
            try regions.append(gpa, ReservedMemoryRegion{
                .range = .{
                    .frame_number = @intCast(entry.address / arch.page_size),
                    .frame_count = @intCast(entry.size / arch.page_size),
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

const minimum_region_frame_count = 8;

fn processRegion(
    allocator: std.mem.Allocator,
    regs: *std.ArrayList(PhysicalMemoryRegion),
    region: PhysicalMemoryRegion,
    reserved_regions: []const ReservedMemoryRegion,
) !void {
    var range = region;

    for (reserved_regions) |resv| {
        if (!range.intersects(resv.range))
            continue;

        const original_end = range.end();
        const resv_end = resv.range.end();

        if (resv.range.frame_number <= range.frame_number) {
            // cut off the interescting part at the beginning of the region
            range.frame_number = resv_end;
            range.frame_count = original_end - range.frame_number;
            continue;
        }

        if (resv_end >= original_end) {
            // cut off the interescting part at the end of the region
            range.frame_count = resv.range.frame_number - range.frame_number;
            continue;
        }

        // the reserved region is inside the physical region
        range.frame_count = resv.range.frame_number - range.frame_number;
        // do the same process for the region on the right side of the reserved region
        const other_region = PhysicalMemoryRegion{
            .frame_number = resv_end,
            .frame_count = original_end - resv_end,
        };

        try processRegion(allocator, regs, other_region, reserved_regions);
    }

    if (range.frame_count >= minimum_region_frame_count)
        try regs.append(allocator, range);
}

fn getUsableRegions(
    allocator: std.mem.Allocator,
    physical_regions: []const PhysicalMemoryRegion,
    reserved_regions: []const ReservedMemoryRegion,
) ![]PhysicalMemoryRegion {
    var regions = std.ArrayList(PhysicalMemoryRegion).empty;

    for (physical_regions) |reg|
        try processRegion(allocator, &regions, reg, reserved_regions);

    return regions.toOwnedSlice(allocator);
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

    const start_addr = kernel_start - arch.kernel_addresses.kernel_virtual_offset;

    try reserved_regions.append(allocator, ReservedMemoryRegion{
        .name = "kernel",
        .no_map = true,
        .reusable = false,
        .system = true,
        .range = PhysicalMemoryRegion{
            .frame_number = start_addr / arch.page_size,
            .frame_count = kernel_size / arch.page_size,
        },
    });
}

fn addDeviceTreeReservedMemory(
    allocator: std.mem.Allocator,
    reserved_regions: *std.ArrayListUnmanaged(ReservedMemoryRegion),
    dt: *const devicetree.DeviceTree,
) !void {
    // we need to reserve memory for the DT itself
    const dt_start = std.mem.alignBackward(u64, @intFromPtr(dt.blob.ptr), arch.page_size);
    const dt_end = std.mem.alignForward(
        u64,
        @intFromPtr(dt.blob.ptr + dt.blob.len),
        arch.page_size,
    );

    const start_address = dt_start - arch.kernel_addresses.kernel_virtual_offset;
    const size = dt_end - dt_start;

    const dt_region = ReservedMemoryRegion{
        .name = "device-tree",
        .no_map = true,
        .reusable = false,
        .system = false,
        .range = PhysicalMemoryRegion{
            .frame_number = start_address / arch.page_size,
            .frame_count = size / arch.page_size,
        },
    };
    try reserved_regions.append(allocator, dt_region);
}

fn printRegions(regions: []const PhysicalMemoryRegion) void {
    for (regions) |range| {
        const size_in_kib = range.frame_count * arch.page_size / 1024;
        const start = range.frame_number * arch.page_size;
        const end = range.end() * arch.page_size - 1;
        log.info("    [0x{x:0>16}-0x{x:0>16}] ({} KiB)", .{ start, end, size_in_kib });
    }
}

fn printReservedRegions(reserved_regions: []const ReservedMemoryRegion) void {
    log.info("Reserved memory regions:", .{});
    for (reserved_regions) |reg| {
        const size_in_kib = reg.range.frame_count * arch.page_size / 1024;
        const start = reg.range.frame_number * arch.page_size;
        const end = reg.range.end() * arch.page_size - 1;

        if (reg.system) {
            log.info("    [0x{x:0>16}-0x{x:0>16}] <{s}> ({} KiB) system", .{
                start,
                end,
                reg.name,
                size_in_kib,
            });
        } else {
            const no_map_string = if (reg.no_map) "no-map" else "map";
            const reusable_string = if (reg.reusable) "reusable" else "non-reusable";
            log.info("    [0x{x:0>16}-0x{x:0>16}] <{s}> ({} KiB) {s} {s}", .{
                start,
                end,
                reg.name,
                size_in_kib,
                no_map_string,
                reusable_string,
            });
        }
    }
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
pub fn clonePageTable(
    page_table: arch.PageTable,
    only_higher_half: bool,
) error{OutOfMemory}!arch.PageTable {
    const new_page_table_frame_desc = buddy_allocator.allocBlock(0) catch |err| switch (err) {
        error.InvalidOrder => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const new_page_table_phys = new_page_table_frame_desc.physical();
    const new_page_table_virt = physicalToVirtual(new_page_table_phys);
    const new_page_table = PageTable.fromVirtualAddress(new_page_table_virt);

    arch.copyPageTable(page_table, new_page_table, only_higher_half);

    return new_page_table;
}

pub const PagefaultType = enum { read, write, instruction };
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

                    const new_frame_desc = buddy_allocator.allocBlock(0) catch @panic("TODO");
                    const new_phys = new_frame_desc.physical();
                    const new_virt = physicalToVirtual(new_phys);
                    const new_page: []u8 = new_virt.asPtr([*]u8)[0..arch.page_size];

                    @memcpy(new_page, backing_page);

                    const remaining_file_size = region.size - backing.size;
                    zeroed_size = arch.page_size - @min(remaining_file_size, arch.page_size);
                    break :blk new_phys;
                } else {
                    const phys = virtualToPhysical(backing_virt);
                    const frame_descriptor = getFrameDescriptor(phys);
                    frame_descriptor.increaseReference();

                    break :blk phys;
                }
            } else blk: {
                zeroed_size = arch.page_size;
                const frame_descriptor = buddy_allocator.allocBlock(0) catch @panic("TODO");
                break :blk frame_descriptor.physical();
            };

            var frames = [1]PhysicalAddress{frame};

            mapRegion(
                process.root_page_table,
                user_address.int / arch.page_size,
                1,
                .{
                    .access = region.flags,
                    .global = false,
                    .user = true,
                    .ignore_if_overwrite = false,
                },
                &frames,
            ) catch @panic("TODO");

            const buff = physicalToVirtual(frame).asPtr([*]u8)[0..zeroed_size];
            @memset(buff, 0);

            return false;
        }
    }

    return true;
}

pub const FrameDescriptor = struct {
    reference_count: std.atomic.Value(u32),
    block_order: u32,

    pub fn increaseReference(self: *FrameDescriptor) void {
        _ = self.reference_count.fetchAdd(1, .monotonic);
    }

    pub fn decreaseReference(self: *FrameDescriptor) void {
        const prev_ref_count = self.reference_count.fetchSub(1, .monotonic);
        if (prev_ref_count == 1)
            buddy_allocator.deallocBlock(self);
    }

    pub fn physical(self: *const FrameDescriptor) PhysicalAddress {
        const relative_addr = @intFromPtr(self) - arch.kernel_addresses.frame_descriptors;
        const page_frame_number = relative_addr / @sizeOf(FrameDescriptor);
        return .fromInt(page_frame_number * arch.page_size);
    }
};

pub const Region = struct {
    frame_number: usize,
    frame_count: usize,
    descriptors: []FrameDescriptor,
};

pub var frame_descriptors = struct {
    spinlock: sync.Spinlock = .unlocked,
    regions: [max_frame_descriptor_region_count]Region = undefined,
    region_count: usize = 0,
}{};

pub const max_frame_descriptor_region_count = 32;

pub fn getFrameDescriptor(address: PhysicalAddress) *FrameDescriptor {
    std.debug.assert(address.int % arch.page_size == 0);
    const pfn = address.int / arch.page_size;

    // TODO: lock interrupt?
    frame_descriptors.spinlock.lock();
    defer frame_descriptors.spinlock.unlock();

    for (0..frame_descriptors.region_count) |i| {
        const region = &frame_descriptors.regions[i];
        if (pfn < region.frame_number or pfn >= region.frame_number + region.frame_count)
            continue;

        const relative_pfn = pfn - region.frame_number;
        return &region.descriptors[relative_pfn];
    }

    unreachable;
}

pub fn setupFrameDescriptors(
    root_page_table: PageTable,
    free_regions: []PhysicalMemoryRegion,
) error{OutOfMemory}!void {
    std.debug.assert(max_frame_descriptor_region_count > free_regions.len);

    for (0..free_regions.len) |i| {
        const free_region = free_regions[i];

        const start_pfn = free_region.frame_number;
        // end_pfn is exclusive
        const end_pfn = free_region.end();

        const desc_arr_pfn = start_pfn * @sizeOf(FrameDescriptor) / arch.page_size;
        const desc_arr_end_pfn = end_pfn * @sizeOf(FrameDescriptor) / arch.page_size;
        const desc_arr_frame_count = desc_arr_end_pfn - desc_arr_pfn + 1;

        try arch.mapRegion(
            root_page_table,
            arch.kernel_addresses.frame_descriptors / arch.page_size + desc_arr_pfn,
            desc_arr_frame_count,
            .{
                .access = .{ .execute = false, .read = true, .write = true },
                .global = true,
                .user = false,
                .ignore_if_overwrite = true,
            },
            null,
            earlyAllocFrame,
        );

        const descriptors_ptr: [*]FrameDescriptor = @ptrFromInt(arch.kernel_addresses.frame_descriptors);

        frame_descriptors.regions[i] = .{
            .frame_count = free_region.frame_count,
            .frame_number = start_pfn,
            .descriptors = descriptors_ptr[start_pfn..end_pfn],
        };
        frame_descriptors.region_count += 1;
    }

    for (0..early_page_allocator.region_index + 1) |region_idx| {
        const region = early_page_allocator.regions[region_idx];
        for (0..region.reserved_frame_count) |frame_idx| {
            const page_frame_number = region.range.frame_number + frame_idx;
            const phys = PhysicalAddress.fromInt(page_frame_number * arch.page_size);
            const descriptor = getFrameDescriptor(phys);
            descriptor.reference_count.store(1, .monotonic);
        }
    }
}

fn buddyAllocFrame() error{OutOfMemory}!PhysicalAddress {
    const frame_desc = buddy_allocator.allocBlock(0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidOrder => unreachable,
    };
    return frame_desc.physical();
}

pub const MapFlags = packed struct {
    access: Process.MappedRegion.Flags,
    user: bool,
    global: bool,
    ignore_if_overwrite: bool,
};

pub fn mapRegion(
    root_page_tbl: PageTable,
    page_number: usize,
    page_count: usize,
    flags: MapFlags,
    frames_to_map: ?[]const PhysicalAddress,
) !void {
    return arch.mapRegion(
        root_page_tbl,
        page_number,
        page_count,
        flags,
        frames_to_map,
        buddyAllocFrame,
    );
}

var early_page_allocator: struct {
    regions: [max_frame_descriptor_region_count]struct {
        range: PhysicalMemoryRegion,
        reserved_frame_count: usize,
    },
    region_index: usize,
    region_count: usize,
} = undefined;

fn earlyAllocFrame() error{OutOfMemory}!PhysicalAddress {
    while (early_page_allocator.region_index < early_page_allocator.regions.len) {
        const region = &early_page_allocator.regions[early_page_allocator.region_index];
        if (region.reserved_frame_count == region.range.frame_count) continue;

        const frame_number = region.range.frame_number + region.reserved_frame_count;
        region.reserved_frame_count += 1;

        return .fromInt(frame_number * arch.page_size);
    }
    return error.OutOfMemory;
}

pub fn init(
    allocator: std.mem.Allocator,
    dt: *const devicetree.DeviceTree,
    root_page_table: PageTable,
) void {
    const phyiscal_regions = parseMemoryRegions(allocator, dt, dt.root()) catch
        @panic("");

    var reserved_regions = parseReservedMemoryRegions(allocator, dt, dt.root()) catch
        @panic("Failed to parse reserved memory regions in DT");
    defer reserved_regions.deinit(allocator);

    addDeviceTreeReservedMemory(allocator, &reserved_regions, dt) catch
        @panic("Failed to add DT as reserved memory");

    addKernelReservedMemory(allocator, &reserved_regions) catch
        @panic("Failed to add kernel as reserved memory");

    log.info("Physical memory regions:", .{});
    printRegions(phyiscal_regions);

    const usable_regions = getUsableRegions(
        allocator,
        phyiscal_regions,
        reserved_regions.items,
    ) catch @panic("Failed to get usable memory regions");

    std.debug.assert(usable_regions.len < max_frame_descriptor_region_count);

    early_page_allocator.region_index = 0;
    early_page_allocator.region_count = usable_regions.len;
    for (0..usable_regions.len) |i| {
        early_page_allocator.regions[i] = .{
            .range = usable_regions[i],
            .reserved_frame_count = 0,
        };
    }
    setupFrameDescriptors(root_page_table, usable_regions) catch
        @panic("Failed to initialize frame descriptors");

    const free_region_count = usable_regions.len - early_page_allocator.region_index;
    var free_regions = allocator.alloc(PhysicalMemoryRegion, free_region_count) catch
        @panic("OOM");

    for (0..usable_regions.len) |i| {
        const reg = usable_regions[i];
        const used_frame_count = early_page_allocator.regions[i].reserved_frame_count;
        if (used_frame_count > 0) {
            reserved_regions.append(
                allocator,
                .{
                    .range = .{
                        .frame_number = reg.frame_number,
                        .frame_count = used_frame_count,
                    },
                    .system = true,
                    .name = "frame-descriptor",
                    .no_map = true,
                    .reusable = false,
                },
            ) catch @panic("OOM");
        }
        free_regions[i] = PhysicalMemoryRegion{
            .frame_number = usable_regions[i].frame_number + used_frame_count,
            .frame_count = usable_regions[i].frame_count - used_frame_count,
        };
    }

    printReservedRegions(reserved_regions.items);
    log.info("Free physical memory regions:", .{});
    printRegions(free_regions);

    buddy_allocator.init(free_regions);
    slab_allocator.init();
}
