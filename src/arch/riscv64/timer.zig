const time = @import("../../time.zig");
const devicetree = @import("../../devicetree.zig");
const csr = @import("csr.zig").CSR;
const sbi = @import("sbi.zig");
const trap = @import("trap.zig");
const std = @import("std");

pub const riscv_clock_source = time.ClockSource{
    .init = init,
    .enable = enable,
    .disable = disable,
    .readCounter = readCounter,
};

// only written once
var counter_cmp: u64 = undefined;

fn init(dt: *const devicetree.DeviceTree) time.ClockSourceInitError!u64 {
    const cpus = dt.getChild(dt.root(), "cpus") orelse
        return error.InvalidDeviceTree;
    const frequency = cpus.getProperty(.timebase_frequency) orelse
        return error.InvalidDeviceTree;

    const ns_per_increment = time.ns_per_second / frequency;
    counter_cmp = time.ns_per_tick / ns_per_increment;

    return frequency;
}

fn enable() void {
    const current_time = csr.time.read();
    const val = current_time + counter_cmp;
    sbi.setTimer(val);
    trap.enableInterrupt(@intCast(@intFromEnum(trap.InterruptCode.supervisor_timer)));
}

fn disable() void {
    trap.disableInterrupt(@intCast(@intFromEnum(trap.InterruptCode.supervisor_timer)));
}

fn readCounter() u64 {
    return csr.time.read();
}

pub fn tick() void {
    time.tick();
    trap.clearPendingInterrupt(@intFromEnum(trap.InterruptCode.supervisor_timer));
    const current_time = csr.time.read();
    const val = current_time + counter_cmp;
    sbi.setTimer(val);
}
