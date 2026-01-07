const std = @import("std");
const root = @import("root");
const mm = root.mm;
const devicetree = root.devicetree;
const kio = root.kio;
const interrupt = root.interrupt;
const riscv_int = @import("trap.zig");

// https://github.com/riscv/riscv-plic-spec
// https://www.starfivetech.com/uploads/sifive-interrupt-cookbook-v1p2.pdf

/// Priorities are u32 values, interrupt source 0 does not exist
const priorities_base_off = 0x0;

/// Pending bits are bitfields organized in u32 values
const pending_bits_base_off = 0x1000;

/// Enable bits are bitfields organized in u32 values
const enable_bits_base_off = 0x2000;

/// Contexts are each 0x1000 bytes apart but only the first two u32s are used, other bytes are reserved
const context_base_off = 0x200000;
const context_priority_threshold_off = 0x0;
const context_claim_off = 0x4;
const context_complete_off = 0x4;
const context_size = 0x1000;

const max_interrupt_count = 1024;
const context_count = 15872;

const PLIC = struct {
    base_ptr: mm.VirtualAddress,
    max_interrupts: u32,
};

const PLICError = error{
    DriverUninitialized,
    InvalidInterruptID,
    InvalidPriority,
    InvalidContext,
    InvalidThreshold,
};

var plic: ?PLIC = null;

pub fn initDriver(dt: *const devicetree.DeviceTree, handle: u32) !void {
    if (plic != null) {
        @panic("PLIC is already initialized");
    }

    const node = dt.nodes.items[handle];

    const max_interrupts = node.getPropertyOtherU32("riscv,ndev") orelse
        return error.InvalidDeviceTree;

    const addressCells = node.getAddressCellFromParent(dt) orelse
        return error.InvalidDeviceTree;

    const reg = node.getProperty(.reg) orelse
        return error.InvalidDeviceTree;
    var reg_it = try reg.iterator(addressCells, 0);
    const base_addr = (reg_it.next() orelse return error.InvalidDeviceTree).addr;
    const phys_addr = mm.PhysicalAddress.make(base_addr);
    const virt_addr = mm.physicalToHHDMAddress(phys_addr);

    plic = .{
        .base_ptr = virt_addr,
        .max_interrupts = max_interrupts,
    };

    try setThreshold(0, 0);

    try interrupt.registerInterruptController(interrupt.InterruptController{
        .enableInterrupt = enableInterruptWrapper,
        .disableInterrupt = disableInterruptWrapper,
        .setPriority = setPriorityWrapper,
        .getPriority = getPriorityWrapper,
        .setHandler = setHandlerWrapper,
    });

    riscv_int.enableInterrupt(@intCast(@intFromEnum(riscv_int.InterruptCode.machine_external)));
    riscv_int.enableInterrupt(@intCast(@intFromEnum(riscv_int.InterruptCode.supervisor_external)));
}

fn enableInterruptWrapper(int_num: usize) interrupt.InterruptController.Error!void {
    const int: u32 = @intCast(int_num);
    // TODO: contexts
    const context = 0;
    enableInterrupt(context, int) catch |err| {
        return switch (err) {
            PLICError.DriverUninitialized => error.ControllerInternalError,
            PLICError.InvalidInterruptID => error.InvalidInterruptID,
            PLICError.InvalidPriority => error.InvalidPriority,
            PLICError.InvalidContext => @panic("invalid context"),
            PLICError.InvalidThreshold => @panic("invalid threshold"),
        };
    };

    enableInterrupt(1, int) catch |err| {
        return switch (err) {
            PLICError.DriverUninitialized => error.ControllerInternalError,
            PLICError.InvalidInterruptID => error.InvalidInterruptID,
            PLICError.InvalidPriority => error.InvalidPriority,
            PLICError.InvalidContext => @panic("invalid context"),
            PLICError.InvalidThreshold => @panic("invalid threshold"),
        };
    };

    enableInterrupt(2, int) catch |err| {
        return switch (err) {
            PLICError.DriverUninitialized => error.ControllerInternalError,
            PLICError.InvalidInterruptID => error.InvalidInterruptID,
            PLICError.InvalidPriority => error.InvalidPriority,
            PLICError.InvalidContext => @panic("invalid context"),
            PLICError.InvalidThreshold => @panic("invalid threshold"),
        };
    };
}

fn disableInterruptWrapper(int_num: usize) interrupt.InterruptController.Error!void {
    const int: u32 = @intCast(int_num);
    // TODO: contexts
    const context = 0;
    disableInterrupt(context, int) catch |err| {
        return switch (err) {
            PLICError.DriverUninitialized => interrupt.InterruptController.Error.ControllerInternalError,
            PLICError.InvalidInterruptID => interrupt.InterruptController.Error.InvalidInterruptID,
            PLICError.InvalidPriority => interrupt.InterruptController.Error.InvalidPriority,
            PLICError.InvalidContext => @panic("invalid context"),
            PLICError.InvalidThreshold => @panic("invalid threshold"),
        };
    };
}

fn setPriorityWrapper(int_num: usize, priority: usize) interrupt.InterruptController.Error!void {
    // TODO: better cast
    const int: u32 = @intCast(int_num);
    const prio: u32 = @intCast(priority);

    setPriority(int, prio) catch |err| {
        return switch (err) {
            PLICError.DriverUninitialized => interrupt.InterruptController.Error.ControllerInternalError,
            PLICError.InvalidInterruptID => interrupt.InterruptController.Error.InvalidInterruptID,
            PLICError.InvalidPriority => interrupt.InterruptController.Error.InvalidPriority,
            PLICError.InvalidContext => @panic("invalid context"),
            PLICError.InvalidThreshold => @panic("invalid threshold"),
        };
    };
}

fn getPriorityWrapper(int_num: usize) interrupt.InterruptController.Error!usize {
    // TODO: better cast
    const int: u32 = @intCast(int_num);

    return getPriority(int) catch |err| {
        return switch (err) {
            PLICError.DriverUninitialized => interrupt.InterruptController.Error.ControllerInternalError,
            PLICError.InvalidInterruptID => interrupt.InterruptController.Error.InvalidInterruptID,
            PLICError.InvalidPriority => interrupt.InterruptController.Error.InvalidPriority,
            PLICError.InvalidContext => @panic("invalid context"),
            PLICError.InvalidThreshold => @panic("invalid threshold"),
        };
    };
}

fn setHandlerWrapper(int_num: usize, handler: *const fn () void) interrupt.InterruptController.Error!void {
    _ = int_num;
    _ = handler;
}

fn setPriority(id: u32, priority: u32) PLICError!void {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (priority > 7) return error.InvalidPriority;

    if (id == 0 or id > inner.max_interrupts) return error.InvalidInterruptID;
    const priorities: [*]u32 = @ptrFromInt(inner.base_ptr.asInt() + priorities_base_off);
    priorities[id] = priority;
}

fn getPriority(id: u32) PLICError!usize {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (id == 0 or id > inner.max_interrupts) return error.InvalidInterruptID;
    const priorities: [*]u32 = @ptrFromInt(inner.base_ptr.asInt() + priorities_base_off);
    return priorities[id];
}

fn getPending(id: u32) PLICError!bool {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (id == 0 or id > inner.max_interrupts) return error.InvalidInterruptID;
    const word = id / @sizeOf(u32);
    const bit = id % @sizeOf(u32);

    const pending_bits: [*]u32 = @ptrFromInt(inner.base_ptr.asInt() + pending_bits_base_off);
    const pending = pending_bits[word] & std.math.shl(u32, 1, bit);
    return pending > 0;
}

fn enableInterrupt(context: u32, id: u32) PLICError!void {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (context > context_count) return error.InvalidContext;
    if (id == 0 or id > inner.max_interrupts) return error.InvalidInterruptID;

    const word = id / @sizeOf(u32);
    const bit = id % @sizeOf(u32);

    const bytes_per_context = max_interrupt_count / @sizeOf(u32);
    const base = inner.base_ptr.asInt() + pending_bits_base_off;
    const context_off = context * bytes_per_context;

    const enable_bits: [*]u32 = @ptrFromInt(base + context_off);
    enable_bits[word] |= std.math.shl(u32, 1, bit);
}

fn disableInterrupt(context: u32, id: u32) PLICError!void {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (context > context_count) return error.InvalidContext;
    if (id == 0 or id > inner.max_interrupts) return error.InvalidInterruptID;

    const word = id / @sizeOf(u32);
    const bit = id % @sizeOf(u32);

    const bytes_per_context = max_interrupt_count / @sizeOf(u32);
    const base = inner.base_ptr.asInt() + pending_bits_base_off;
    const context_off = context * bytes_per_context;

    const enable_bits: [*]u32 = @ptrFromInt(base + context_off);
    enable_bits[word] &= ~std.math.shl(u32, 1, bit);
}

fn setThreshold(context: u32, threshold: u32) PLICError!void {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (threshold > 7) return error.InvalidThreshold;

    const base = inner.base_ptr.asInt() + context_base_off;
    const context_off = context * context_size + context_priority_threshold_off;

    const context_threshold: *u32 = @ptrFromInt(base + context_off);
    context_threshold.* = threshold;
}

fn claim(context: u32) PLICError!u32 {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (context > context_count) return error.InvalidContext;

    const base = inner.base_ptr.asInt() + context_base_off;
    const context_off = context * context_size + context_claim_off;

    const context_claim: *u32 = @ptrFromInt(base + context_off);
    const interrupt_id = context_claim.*;

    return interrupt_id;
}

fn complete(context: u32, id: u32) PLICError!void {
    const inner = plic orelse return error.DriverUninitialized;
    // TODO: locking

    if (context > context_count) return error.InvalidContext;

    const base = inner.base_ptr.asInt() + context_base_off;
    const context_off = context * context_size + context_complete_off;

    const context_complete: *u32 = @ptrFromInt(base + context_off);
    context_complete.* = id;
}
