const std = @import("std");
const mm = @import("../../mem/mm.zig");
const kio = @import("../../kio.zig");

pub const entries_per_tbl = 512;

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
};

// TODO: support other addressing modes like Sv48, Sv57...
pub const Sv39PhysicalAddress = packed struct(u64) {
    offset: u12,
    page_num_0: u9,
    page_num_1: u9,
    page_num_2: u9,
    __unused: u25,

    const Self = @This();

    pub inline fn make(addr: u64) Self {
        return @bitCast(addr);
    }

    pub inline fn asInt(self: Self) u64 {
        return @bitCast(self);
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

    pub inline fn make(addr: u64) Self {
        return @bitCast(addr);
    }

    pub inline fn asInt(self: Self) u64 {
        return @bitCast(self);
    }

    pub inline fn isPageAligned(self: Self) bool {
        return self.offset == 0;
    }
};

pub const PageTable = struct {
    entries: *[entries_per_tbl]PageTableEntry,

    const Self = @This();

    pub inline fn fromAddress(addr: u64) PageTable {
        return .{
            .entries = @ptrFromInt(addr),
        };
    }

    pub inline fn writeEntry(
        self: *Self,
        idx: usize,
        phys: Sv39PhysicalAddress,
        entryType: PageEntryType,
        flags: PageTableEntry.Flags,
    ) !void {
        if (idx >= entries_per_tbl)
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

    // inline for the same reason as fromAddress
    pub inline fn zeroEntry(self: *Self, idx: usize) !void {
        if (idx >= entries_per_tbl)
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

pub var root_page_table: PageTable = undefined;

fn writeSATP(satp: SATP) void {
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

pub fn setupPaging(root_page_table_virt: usize) void {
    root_page_table = PageTable{ .entries = @ptrFromInt(root_page_table_virt) };

    // map 128GiB directly
    for (256..256 + 128, 0..) |i, j| {
        const phys_addr = Sv39PhysicalAddress.make(j * (1024 * 1024 * 1024));
        root_page_table.writeEntry(
            i,
            phys_addr,
            PageEntryType.leaf1G,
            PageTableEntry.Flags{
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
