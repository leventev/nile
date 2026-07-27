const std = @import("std");
const mm = @import("../../mem/mm.zig");
const kio = @import("../../kio.zig");
const Process = @import("../../Process.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");
const vfs = @import("../../vfs.zig");

pub const page_size = 4096;
pub const entries_per_table = 512;

const sv39_higher_half_start = mm.calculateHigherHalfAddress(39);

pub const higherHalfAddress = sv39_higher_half_start;

pub const SATP = packed struct(u64) {
    physical_page_number: u44,
    address_space_id: u16,
    mode: Mode,

    pub const Mode = enum(u4) {
        bare = 0,
        sv39 = 8,
        sv48 = 9,
        sv57 = 10,
        sv64 = 11,
    };
};

pub const PageEntryType = enum {
    branch,
    leaf_4kib,
    leaf_2mib,
    leaf_1gib,
};

pub const PageTableEntry = packed struct(u64) {
    valid: bool,
    flags: Flags,
    accessed: bool,
    dirty: bool,
    __reserved: u2,
    page_number_0: u9,
    page_number_1: u9,
    page_number_2: u9,
    __reserved2: u27,

    pub const Flags = packed struct(u5) {
        readable: bool,
        writable: bool,
        executable: bool,
        user: bool,
        global: bool,
    };

    const Self = @This();

    pub inline fn isZero(self: Self) bool {
        return @as(u64, @bitCast(self)) == 0;
    }

    pub inline fn isBranch(self: Self) bool {
        return !self.flags.readable and !self.flags.writable and !self.flags.readable;
    }

    pub inline fn address(self: Self) mm.PhysicalAddress {
        const addend2 = @shlExact(@as(u64, self.page_number_2), 30);
        const addend1 = @shlExact(@as(u64, self.page_number_1), 21);
        const addend0 = @shlExact(@as(u64, self.page_number_0), 12);
        return .fromInt(addend2 + addend1 + addend0);
    }
};

// TODO: if i make this a packed struct i could just @bitCast the address to this
// but that should be implemented once Sv49 and Sv57 are supported
const PageNumbers = struct {
    page_offset: u12,
    page_number_0: u9,
    page_number_1: u9,
    page_number_2: u9,

    // TODO: Sv48
    // page_number_3: u9,

    // TODO: Sv57
    // page_number_4: u9,

    fn fromInt(addr: u64) PageNumbers {
        return .{
            .page_offset = @truncate(addr),
            .page_number_0 = @truncate(std.math.shr(u64, addr, 12)),
            .page_number_1 = @truncate(std.math.shr(u64, addr, 12 + 9)),
            .page_number_2 = @truncate(std.math.shr(u64, addr, 12 + 18)),
        };
    }

    fn fromVirtual(virt: mm.VirtualAddress) PageNumbers {
        return fromInt(virt.int);
    }

    fn fromPhysical(phys: mm.PhysicalAddress) PageNumbers {
        return fromInt(phys.int);
    }
};

pub const PageTable = struct {
    entries: *[entries_per_table]PageTableEntry,

    const Self = @This();

    pub inline fn fromVirtualAddress(addr: mm.VirtualAddress) PageTable {
        return .{
            .entries = addr.asPtr(*[entries_per_table]PageTableEntry),
        };
    }

    pub inline fn writeEntry(
        self: Self,
        idx: usize,
        phys: mm.PhysicalAddress,
        entry_type: PageEntryType,
        flags: PageTableEntry.Flags,
    ) !void {
        if (idx >= entries_per_table)
            return error.InvalidIdx;

        if (!phys.isPageAligned())
            return error.InvalidAddress;

        const pn = PageNumbers.fromPhysical(phys);

        _ = switch (entry_type) {
            PageEntryType.leaf_2mib => if (pn.page_number_0 != 0)
                return error.InvalidAddress,
            PageEntryType.leaf_1gib => if (pn.page_number_0 != 0 or pn.page_number_1 != 0)
                return error.InvalidAddress,
            PageEntryType.branch => if (flags.executable or flags.readable or flags.writable)
                return error.InvalidFlags,
            else => {},
        };

        self.entries[idx] = PageTableEntry{
            .valid = true,
            .flags = flags,
            .accessed = false,
            .dirty = false,
            .page_number_0 = pn.page_number_0,
            .page_number_1 = pn.page_number_1,
            .page_number_2 = pn.page_number_2,
            .__reserved = 0,
            .__reserved2 = 0,
        };
    }

    pub inline fn zeroEntry(self: Self, idx: usize) !void {
        if (idx >= entries_per_table)
            return error.InvalidIdx;

        self.entries[idx] = PageTableEntry{
            .valid = false,
            .flags = PageTableEntry.Flags{
                .executable = false,
                .writable = false,
                .readable = false,
                .global = false,
                .user = false,
            },
            .accessed = false,
            .dirty = false,
            .page_number_0 = 0,
            .page_number_1 = 0,
            .page_number_2 = 0,
            .__reserved = 0,
            .__reserved2 = 0,
        };
    }
};

pub fn writeSATP(satp: SATP) void {
    const val: u64 = @bitCast(satp);
    asm volatile ("csrw satp, %[satp]"
        :
        : [satp] "r" (val),
    );
}

pub fn readSATP() SATP {
    var val: u64 = undefined;
    asm volatile ("csrr %[satp], satp"
        : [satp] "=r" (val),
    );

    return @bitCast(val);
}

fn flushPage(virt_addr: ?usize, asid: ?usize) void {
    if (asid) |as| {
        if (virt_addr) |virt| {
            asm volatile ("sfence.vma %[virt], %[asid]"
                :
                : [virt] "r" (virt),
                  [asid] "r" (as),
            );
        } else {
            asm volatile ("sfence.vma x0, %[asid]"
                :
                : [asid] "r" (as),
            );
        }
    } else {
        asm volatile ("sfence.vma x0, x0");
    }
}

fn getOrMapPageTable(parent_page_tbl: PageTable, index: usize) !PageTable {
    const pg_tbl_entry = parent_page_tbl.entries[index];
    const pg_tbl_ptr =
        if (pg_tbl_entry.isZero()) blk: {
            const frame = try buddy_allocator.allocBlock(0);
            parent_page_tbl.writeEntry(
                index,
                frame,
                .branch,
                .{
                    .executable = false,
                    .readable = false,
                    .writable = false,
                    .global = false,
                    .user = false,
                },
            ) catch unreachable;

            const virt = mm.physicalToVirtualAddress(frame);
            const ptr = @as([*]u64, @ptrFromInt(virt.int));
            const page: []u64 = ptr[0..entries_per_table];
            @memset(page, 0);

            break :blk page.ptr;
        } else blk: {
            const frame = pg_tbl_entry.address();

            const virt = mm.physicalToVirtualAddress(frame);
            const ptr = @as([*]u64, @ptrFromInt(virt.int));
            break :blk ptr;
        };

    return .{ .entries = @ptrCast(pg_tbl_ptr) };
}

pub fn switchAddressSpace(root_page_table: PageTable) void {
    const pg_tbl_virt = mm.VirtualAddress.fromInt(@intFromPtr(root_page_table.entries));
    const pg_tbl_ppn: u44 = @intCast(mm.virtualToPhysicalAddress(pg_tbl_virt).int / page_size);
    writeSATP(.{
        .address_space_id = 0,
        .mode = .sv39,
        .physical_page_number = pg_tbl_ppn,
    });

    // TODO: dont always flush TLB
    flushPage(null, null);
}

// TODO: for now i will keep this function which can map multiple pages at once
// but if in the future there is no need for that then this should be replaced
// with a function that only maps a single page
pub fn mapRegion(
    root_page_tbl: PageTable,
    page_number: usize,
    page_count: usize,
    flags: Process.MappedRegion.Flags,
    frames: []const mm.PhysicalAddress,
) !void {
    const start_addr = mm.VirtualAddress.fromInt(page_number * page_size);
    const end_addr = start_addr.add(page_count * page_size);

    // set them equal so on the first iteration loading
    // the page tables gets skipped
    var prev_addr = start_addr;
    var current_addr = start_addr;

    // in Sv39 we have 3 levels of page tables
    // level 2 is the highest(root page table)
    const pg_tbl_2 = root_page_tbl;

    const pn = PageNumbers.fromVirtual(current_addr);
    var pg_tbl_1 = try getOrMapPageTable(pg_tbl_2, pn.page_number_2);
    var pg_tbl_0 = try getOrMapPageTable(pg_tbl_1, pn.page_number_1);

    var page_idx: usize = 0;

    while (end_addr.int != current_addr.int) : (page_idx += 1) {
        const prev_pn = PageNumbers.fromVirtual(prev_addr);
        const current_pn = PageNumbers.fromVirtual(current_addr);

        if (prev_pn.page_number_2 != current_pn.page_number_2) {
            pg_tbl_1 = try getOrMapPageTable(pg_tbl_2, current_pn.page_number_2);
        }

        if (prev_pn.page_number_1 != current_pn.page_number_1) {
            pg_tbl_0 = try getOrMapPageTable(pg_tbl_1, current_pn.page_number_1);
        }

        const prev_entry = pg_tbl_0.entries[current_pn.page_number_0];
        if (!prev_entry.isZero()) {
            std.log.warn("overwriting page table mapping(VPN={},{},{})", .{
                current_pn.page_number_2,
                current_pn.page_number_1,
                current_pn.page_number_0,
            });
        }

        const frame = frames[page_idx];

        pg_tbl_0.writeEntry(current_pn.page_number_0, frame, .leaf_4kib, .{
            .executable = flags.execute,
            .readable = flags.read,
            .writable = flags.write,
            .global = false,
            .user = true,
        }) catch unreachable;

        flushPage(current_addr.int, 0);

        prev_addr = current_addr;
        current_addr = current_addr.add(page_size);
    }
}

pub fn copyPageTable(
    original_page_table: PageTable,
    new_page_table: PageTable,
    only_higher_half: bool,
) void {
    const higher_half = PageNumbers.fromVirtual(higherHalfAddress);

    const subtable_start_idx = if (only_higher_half) blk: {
        @memset(new_page_table.entries[0..higher_half.page_number_2], @bitCast(@as(u64, 0)));
        break :blk higher_half.page_number_2;
    } else 0;

    const new_subtable = new_page_table.entries[subtable_start_idx..entries_per_table];
    const orig_subtable = original_page_table.entries[subtable_start_idx..entries_per_table];

    @memcpy(new_subtable, orig_subtable);
}

pub fn unmapPageTable(
    page_table: PageTable,
    level: usize,
    base_address: mm.VirtualAddress,
) void {
    // NOTE: the root page table above 256th index contains kernel mappings which must not be unmapped
    const is_root_pg_tbl = level == 2;
    const end_idx: usize = if (is_root_pg_tbl) 256 else 512;

    for (0..end_idx) |i| {
        // NOTE: since in level 2 we only iterate until 256 we do not need to deal
        // with sign extending the addresses
        const address = base_address.add(i * std.math.shl(u64, 1, 12 + level * 9));
        const entry = page_table.entries[i];
        if (entry.isZero()) continue;

        const frame = entry.address();
        if (entry.isBranch()) {
            std.debug.assert(level > 0);

            const virt = mm.physicalToVirtualAddress(frame);
            const lower_level_pg_tbl = PageTable.fromVirtualAddress(virt);
            unmapPageTable(lower_level_pg_tbl, level - 1, address);
        } else {
            flushPage(address.int, 0);
        }

        const block_order: usize = if (entry.isBranch()) 0 else switch (level) {
            0 => 0,
            1 => 9,
            2 => @panic("TODO: support 1GiB pages"),
            else => unreachable,
        };
        buddy_allocator.deallocBlock(frame, block_order);
    }
}

pub fn unmapAddressSpace(root_page_table: PageTable) void {
    unmapPageTable(root_page_table, 2, .fromInt(0));
    const page_tbl_virt_ptr = mm.VirtualAddress.fromInt(@intFromPtr(root_page_table.entries));
    const root_page_table_addr = mm.virtualToPhysicalAddress(page_tbl_virt_ptr);
    buddy_allocator.deallocBlock(root_page_table_addr, 0);
}

pub fn setupPaging(root_page_table: PageTable) void {
    // map 128GiB directly
    for (256..256 + 128, 0..) |i, j| {
        const phys_addr = mm.PhysicalAddress.fromInt(j * (1024 * 1024 * 1024));
        root_page_table.writeEntry(
            i,
            phys_addr,
            .leaf_1gib,
            .{
                .executable = false,
                .readable = true,
                .writable = true,
                .user = false,
                .global = true,
            },
        ) catch unreachable;
    }

    // unmap identity mapping
    root_page_table.zeroEntry(2) catch unreachable;

    // TODO: flush individual pages
    flushPage(null, 0);
}
