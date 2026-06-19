//! https://github.com/riscv/riscv-plic-spec

const std = @import("std");
const root = @import("root");
const mm = @import("../../mem/mm.zig");
const devicetree = @import("../../dt/devicetree.zig");
const interrupt = @import("../../interrupt.zig");
const riscv_int = @import("../../arch/riscv64/trap.zig");
const Module = @import("../../Module.zig");
const CSR = @import("../../arch/riscv64/csr.zig").CSR;

const log = std.log.scoped(.plic);

/// Priorities are u32 values, interrupt source 0 does not exist.
const priorities_base_off = 0x0;

/// Pending bits are bitfields organized in u32 values.
const pending_bits_base_off = 0x1000;

/// Enable bits are bitfields organized in u32 values.
/// Unlike the pending bits, these are per context.
const enable_bits_base_off = 0x2000;

/// Each context has a threshhold, claim and complete register.
/// They are each 0x1000 bytes apart, all other bytes are reserved.
const context_base_off = 0x20_0000;

/// Offset of the threshhold register from the base address of a context's registers.
const context_priority_threshold_off = 0x0;

/// Offset of the claim register from the base address of a context's registers.
const context_claim_off = 0x4;

/// Offset of the complete register from the base address of a context's registers.
const context_complete_off = 0x4;

/// Size of a context's registers.
const context_size = 0x1000;

/// Maximum number of interrupts possible, the actual number is read from the device tree.
const max_interrupt_count = 1024;

/// Maximum number of contexts possible, the actual number is read from the device tree.
const max_context_count = 15872;

const PLIC = struct {
    base_ptr: mm.VirtualAddress,
    interrupt_count: u32,
    context_count: u32,
    used_context: u32,

    fn setPriority(self: *const PLIC, id: u32, priority: u32) void {
        std.debug.assert(id > 0 and id < self.interrupt_count);
        std.debug.assert(priority < 7);

        // TODO: locking

        const priorities = self.base_ptr.add(priorities_base_off).asPtr([*]u32);
        priorities[id] = priority;
    }

    fn getPriority(self: *const PLIC, id: u32) usize {
        std.debug.assert(id > 0 and id < self.interrupt_count);

        // TODO: locking

        const priorities = self.base_ptr.add(priorities_base_off).asPtr([*]u32);
        return priorities[id];
    }

    fn getPending(self: *const PLIC, id: u32) bool {
        std.debug.assert(id > 0 and id < self.interrupt_count);

        // TODO: locking

        const word = id / @sizeOf(u32);
        const bit = id % @sizeOf(u32);

        const pending_bits = self.base_ptr.add(pending_bits_base_off).asPtr([*]u32);
        const pending = pending_bits[word] & std.math.shl(u32, 1, bit);
        return pending > 0;
    }

    fn enableInterrupt(self: *const PLIC, context: u32, id: u32) void {
        std.debug.assert(id > 0 and id < self.interrupt_count);
        std.debug.assert(context < self.context_count);

        // TODO: locking

        const idx = id / @bitSizeOf(u32);
        const bit = id % @bitSizeOf(u32);

        const bytes_per_context = max_interrupt_count / @bitSizeOf(u8);
        const context_off = context * bytes_per_context;

        const offset = enable_bits_base_off + context_off;
        const enable_bits = self.base_ptr.add(offset).asPtr([*]u32);
        enable_bits[idx] |= std.math.shl(u32, 1, bit);
    }

    fn disableInterrupt(self: *const PLIC, context: u32, id: u32) void {
        std.debug.assert(id > 0 and id < self.interrupt_count);
        std.debug.assert(context < self.context_count);

        // TODO: locking

        const idx = id / @bitSizeOf(u32);
        const bit = id % @bitSizeOf(u32);

        const bytes_per_context = max_interrupt_count / @bitSizeOf(u8);
        const context_off = context * bytes_per_context;

        const offset = enable_bits_base_off + context_off;
        const enable_bits = self.base_ptr.add(offset).asPtr([*]u32);
        enable_bits[idx] &= ~std.math.shl(u32, 1, bit);
    }

    fn dumpPendingInterrupts(self: *const PLIC) void {
        const base = self.base_ptr.add(pending_bits_base_off);
        const pending_bits = base.asPtr([*]u32);

        const dwords = self.interrupt_count / @bitSizeOf(u32);

        for (0..dwords) |dword_idx| {
            log.debug("0x{x}({}-{}): {b:032}", .{
                @intFromPtr(&pending_bits[dword_idx]),
                dword_idx * 32,
                (dword_idx + 1) * 32 - 1,
                pending_bits[dword_idx],
            });
        }
    }

    fn dumpEnabledInterrupts(self: *const PLIC) void {
        const bytes_per_context = max_interrupt_count / @bitSizeOf(u8);
        const context_off = self.used_context * bytes_per_context;

        const offset = enable_bits_base_off + context_off;
        const enabled_bits = self.base_ptr.add(offset).asPtr([*]u32);

        const dwords = self.interrupt_count / @bitSizeOf(u32);

        for (0..dwords) |dword_idx| {
            log.debug("0x{x}({}-{}): {b:032}", .{
                @intFromPtr(&enabled_bits[dword_idx]),
                dword_idx * 32,
                (dword_idx + 1) * 32 - 1,
                enabled_bits[dword_idx],
            });
        }
    }

    fn setThreshold(self: *const PLIC, context: u32, threshold: u32) void {
        std.debug.assert(threshold < 7);
        std.debug.assert(context < self.context_count);

        // TODO: locking

        const offset = context_base_off + context * context_size + context_priority_threshold_off;

        const context_threshold = self.base_ptr.add(offset).asPtr(*u32);
        context_threshold.* = threshold;
    }

    fn claim(self: *const PLIC, context: u32) u32 {
        std.debug.assert(context < self.context_count);

        // TODO: locking

        const offset = context_base_off + context * context_size + context_claim_off;
        const context_claim = self.base_ptr.add(offset).asPtr(*u32);

        const interrupt_id = context_claim.*;
        return interrupt_id;
    }

    fn complete(self: *const PLIC, context: u32, id: u32) void {
        std.debug.assert(context < self.context_count);
        std.debug.assert(id < self.interrupt_count);

        // TODO: locking

        const offset = context_base_off + context * context_size + context_complete_off;
        const context_complete = self.base_ptr.add(offset).asPtr(*u32);

        context_complete.* = id;
    }
};

var plic: PLIC = undefined;

fn init(dt: *const devicetree.DeviceTree, handle: u32) error{InvalidDeviceTree}!void {
    const node = dt.nodes.items[handle];

    const interrupt_count = node.getPropertyOtherU32("riscv,ndev") orelse
        return error.InvalidDeviceTree;

    const address_cells = node.getAddressCellFromParent(dt);
    std.debug.assert(address_cells <= 2);

    const reg = node.getProperty(.reg) orelse return error.InvalidDeviceTree;
    var reg_it = reg.iterator(address_cells, 0) catch return error.InvalidDeviceTree;
    const first_reg = reg_it.next() orelse return error.InvalidDeviceTree;

    const phys_addr_int: u64 = @intCast(first_reg.address);
    const phys_addr = mm.PhysicalAddress.fromInt(phys_addr_int);
    const virt_addr = mm.physicalToVirtualAddress(phys_addr);

    const interrupts_extended = node.getProperty(.interrupts_extended) orelse
        return error.InvalidDeviceTree;
    var int_ext_it = interrupts_extended.iterator(dt);

    var context_count: u32 = 0;
    var used_context: ?u32 = null;
    while (int_ext_it.next()) |int_ext| : (context_count += 1) {
        if (int_ext.interrupt_specifier == std.math.maxInt(u32))
            continue;

        if (used_context == null)
            used_context = context_count
        else
            log.warn("#{} context is used but ignored", .{context_count});
    }

    plic = .{
        .base_ptr = virt_addr,
        .interrupt_count = interrupt_count,
        .context_count = context_count,
        .used_context = used_context orelse return error.InvalidDeviceTree,
    };

    interrupt.registerInterruptController(interrupt.InterruptController{
        .max_interrupt = interrupt_count - 1,
        .enableInterrupt = enableInterruptWrapper,
        .disableInterrupt = disableInterruptWrapper,
        .dumpPendingInterrupts = dumpPendingInterrupts,
        .dumpEnabledInterrupts = dumpEnabledInterrupts,
    }) catch @panic("Failed to register interrupt controller");

    // we set the threshhold to 0 and the individual priorities to 1
    // to essentially disable the threshhold mechanism
    plic.setThreshold(plic.used_context, 0);

    riscv_int.enableInterrupt(@intCast(@intFromEnum(riscv_int.InterruptCode.supervisor_external)));
}

fn enableInterruptWrapper(int_num: usize) void {
    const id: u32 = @intCast(int_num);
    plic.enableInterrupt(plic.used_context, id);
    plic.setPriority(id, 1);
}

fn disableInterruptWrapper(int_num: usize) void {
    const id: u32 = @intCast(int_num);
    plic.disableInterrupt(plic.used_context, id);
}

fn dumpPendingInterrupts() void {
    plic.dumpPendingInterrupts();
}

fn dumpEnabledInterrupts() void {
    plic.dumpEnabledInterrupts();
}

// TODO: handle interrutps nicely instead of directly calling this
// from the riscv interrupt handler
pub fn handleInterrupt() void {
    const int_num = plic.claim(plic.used_context);

    interrupt.dispatchInterrupt(int_num);

    plic.complete(plic.used_context, int_num);
}

pub const module: Module = .{
    .name = "plic",
    .module_type = .{
        .device_driver = .{
            .devicetree = .{
                // TODO: way more compatible than this
                .compatible = &.{ "riscv,plic0", "sifive,plic-1.0.0" },
                .init = init,
            },
        },
    },
};
