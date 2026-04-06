const std = @import("std");
const mm = @import("../../mem/mm.zig");
const kio = @import("../../kio.zig");
const Process = @import("../../Process.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");

pub const page_size = 4096;
pub const entries_per_table = 512;

pub const SATP = packed struct(u64) {
    phys_page_num: u44,
    addr_space_id: u16,
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
    leaf4K,
    leaf2M,
    leaf1G,
};

pub const PageTableEntry = packed struct(u64) {
    valid: bool,
    flags: Flags,
    accessed: bool,
    dirty: bool,
    __reserved: u2,
    page_num_0: u9,
    page_num_1: u9,
    page_num_2: u9,
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

    pub inline fn address(self: Self) Sv39PhysicalAddress {
        const addend2 = @shlExact(@as(u64, self.page_num_2), 30);
        const addend1 = @shlExact(@as(u64, self.page_num_1), 21);
        const addend0 = @shlExact(@as(u64, self.page_num_0), 12);
        return .fromInt(addend2 + addend1 + addend0);
    }
};

// TODO: support other addressing modes like Sv48, Sv57...
pub const Sv39PhysicalAddress = packed struct(u64) {
    offset: u12,
    page_num_0: u9,
    page_num_1: u9,
    page_num_2: u9,
    __unused: u25,

    const Self = @This();

    pub inline fn fromInt(addr: u64) Self {
        return @bitCast(addr);
    }

    pub inline fn asInt(self: Self) u64 {
        return @bitCast(self);
    }

    pub inline fn add(self: Self, offset: u64) Self {
        return fromInt(self.asInt() + offset);
    }

    pub inline fn isPageAligned(self: Self) bool {
        return self.offset == 0;
    }
};

pub const Sv39VirtualAddress = packed struct(u64) {
    offset: u12,
    page_num_0: u9,
    page_num_1: u9,
    page_num_2: u9,
    __unused: u25,

    const Self = @This();

    pub inline fn fromInt(addr: u64) Self {
        return @bitCast(addr);
    }

    pub inline fn asInt(self: Self) u64 {
        return @bitCast(self);
    }

    pub inline fn add(self: Self, offset: u64) Self {
        return fromInt(self.asInt() + offset);
    }

    pub inline fn isPageAligned(self: Self) bool {
        return self.offset == 0;
    }
};

pub const PageTable = struct {
    entries: *[entries_per_table]PageTableEntry,

    const Self = @This();

    pub inline fn fromVirtualAddress(addr: Sv39VirtualAddress) PageTable {
        return .{
            .entries = @ptrFromInt(addr.asInt()),
        };
    }

    pub inline fn writeEntry(
        self: Self,
        idx: usize,
        phys: Sv39PhysicalAddress,
        entryType: PageEntryType,
        flags: PageTableEntry.Flags,
    ) !void {
        if (idx >= entries_per_table)
            return error.InvalidIdx;

        if (!phys.isPageAligned())
            return error.InvalidAddress;

        _ = switch (entryType) {
            PageEntryType.leaf2M => if (phys.page_num_0 != 0)
                return error.InvalidAddress,
            PageEntryType.leaf1G => if (phys.page_num_0 != 0 or phys.page_num_1 != 0)
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
            .page_num_0 = phys.page_num_0,
            .page_num_1 = phys.page_num_1,
            .page_num_2 = phys.page_num_2,
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
            .page_num_0 = 0,
            .page_num_1 = 0,
            .page_num_2 = 0,
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
            const ptr = @as([*]u64, @ptrFromInt(virt.asInt()));
            const page: []u64 = ptr[0..entries_per_table];
            @memset(page, 0);

            break :blk page.ptr;
        } else blk: {
            const frame = pg_tbl_entry.address();

            const virt = mm.physicalToVirtualAddress(frame);
            const ptr = @as([*]u64, @ptrFromInt(virt.asInt()));
            break :blk ptr;
        };

    return .{ .entries = @ptrCast(pg_tbl_ptr) };
}

pub fn switchAddressSpace(root_page_table: PageTable) void {
    const pg_tbl_virt = Sv39VirtualAddress.fromInt(@intFromPtr(root_page_table.entries));
    const pg_tbl_ppn: u44 = @intCast(mm.virtualToPhysicalAddress(pg_tbl_virt).asInt() / 4096);
    writeSATP(.{
        .addr_space_id = 0,
        .mode = .sv39,
        .phys_page_num = pg_tbl_ppn,
    });

    // TODO: dont always flush TLB
    flushPage(null, 0);
}

pub fn mapRegion(
    root_page_tbl: PageTable,
    addr: Sv39VirtualAddress,
    size: usize,
    flags: Process.MappedRegion.Flags,
) !void {
    // TODO: instead of addr we should provide the page number and instead of size provide page_count
    std.debug.assert(addr.asInt() % page_size == 0);
    std.debug.assert(size % page_size == 0);

    // in Sv39 we have 3 levels of page tables
    // level 2 is the highest(root page table)
    const pg_tbl_2 = root_page_tbl;
    var pg_tbl_1: PageTable = undefined;
    var pg_tbl_0: PageTable = undefined;

    const start_addr = addr;
    const end_addr = Sv39VirtualAddress.fromInt(addr.asInt() + size);

    var prev_addr: ?Sv39VirtualAddress = null;
    var current_addr = start_addr;

    while (end_addr.asInt() != current_addr.asInt()) {
        if (prev_addr == null or prev_addr.?.page_num_2 != current_addr.page_num_2) {
            pg_tbl_1 = try getOrMapPageTable(pg_tbl_2, current_addr.page_num_2);
        }

        if (prev_addr == null or prev_addr.?.page_num_1 != current_addr.page_num_1) {
            pg_tbl_0 = try getOrMapPageTable(pg_tbl_1, current_addr.page_num_1);
        }

        const prev_entry = pg_tbl_0.entries[current_addr.page_num_0];
        if (!prev_entry.isZero()) {
            std.log.warn("overwriting page table mapping(VPN={},{},{})", .{
                current_addr.page_num_2,
                current_addr.page_num_1,
                current_addr.page_num_0,
            });
        }

        const frame = try buddy_allocator.allocBlock(0);
        pg_tbl_0.writeEntry(current_addr.page_num_0, frame, .leaf4K, .{
            .executable = flags.execute,
            .readable = flags.read,
            .writable = flags.write,
            .global = false,
            .user = true,
        }) catch unreachable;

        flushPage(current_addr.asInt(), 0);

        prev_addr = current_addr;
        current_addr = current_addr.add(page_size);
    }
}

pub fn copyPageTable(original_page_table: PageTable, new_page_table: PageTable) void {
    @memcpy(new_page_table.entries, original_page_table.entries);
}

pub fn unmapPageTable(
    page_table: PageTable,
    level: usize,
    base_address: Sv39VirtualAddress,
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
            flushPage(address.asInt(), 0);
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
    unmapPageTable(root_page_table, 2, Sv39VirtualAddress.fromInt(0));
    const page_tbl_virt_ptr = Sv39VirtualAddress.fromInt(@intFromPtr(root_page_table.entries));
    const root_page_table_addr = mm.virtualToPhysicalAddress(page_tbl_virt_ptr);
    buddy_allocator.deallocBlock(root_page_table_addr, 0);
}

pub fn setupPaging(root_page_table: PageTable) void {
    // map 128GiB directly
    for (256..256 + 128, 0..) |i, j| {
        const phys_addr = Sv39PhysicalAddress.fromInt(j * (1024 * 1024 * 1024));
        root_page_table.writeEntry(
            i,
            phys_addr,
            .leaf1G,
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
