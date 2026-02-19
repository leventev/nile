const std = @import("std");
const sbi = @import("sbi.zig");
const mm = @import("mm.zig");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");
pub const Registers = @import("registers.zig").Registers;
const scheduler = @import("../../scheduler.zig");
const Thread = @import("../../Thread.zig");
const CSR = @import("csr.zig").CSR;
const config = @import("../../config.zig");
pub const Lock = @import("Lock.zig");

pub const VirtualAddress = mm.Sv39VirtualAddress;
pub const PhysicalAddress = mm.Sv39PhysicalAddress;

pub const enableInterrupts = trap.enableInterrupts;
pub const disableInterrupts = trap.disableInterrupts;

extern const __global_pointer: ?void;

pub fn setupNewThread(thread: *Thread, entry_point_addr: usize, stack_top: usize) void {
    if (config.debug_scheduler) {
        thread.registers.gprs = [_]u64{0xAA_BB_CC_DD_AA_BB_CC_DD} ** Registers.gpr_count;
    } else {
        thread.registers.gprs = [_]u64{0x00} ** Registers.gpr_count;
    }

    thread.registers.pc = @intCast(entry_point_addr);
    // TODO: maybe dont copy sstatus?
    thread.registers.status = @bitCast(CSR.sstatus.read());
    thread.registers.gprs[Registers.stack_ptr] = @intCast(stack_top);
    thread.registers.gprs[Registers.global_data_ptr] = @intFromPtr(&__global_pointer);
}

pub fn scheduleNextThread(thread: *Thread) void {
    if (config.debug_scheduler) {
        thread.registers.printRegs(.debug);
    }
    CSR.sscratch.write(@intFromPtr(&thread.registers));
}

pub const clock_source = timer.riscv_clock_source;

fn sbiWriteBytes(bytes: []const u8) ?usize {
    sbi.debugConsoleWrite(bytes) catch return null;
    return bytes.len;
}

pub fn init() linksection(".init") void {
    kio.addBackend(.{
        .name = "riscv64-sbi",
        .priority = 100,
        .writeBytes = sbiWriteBytes,
    }) catch unreachable;

    std.log.info("Starting nile(riscv64)...", .{});
    const sbi_version = sbi.getSpecificationVersion();
    const sbi_version_major = sbi_version >> 24;
    const sbi_version_minor = sbi_version & 0x00FFFFFF;
    const sbi_impl_id = sbi.getImplementationID();
    const sbi_impl_str: []const u8 = if (sbi_impl_id < sbi.sbi_implementations.len)
        sbi.sbi_implementations[sbi_impl_id]
    else
        "Unknown";
    const sbi_implementation_version = sbi.getImplementationVersion();

    std.log.info("SBI specification version: {}.{}", .{ sbi_version_major, sbi_version_minor });
    std.log.info("SBI implementation: {s} (ID={x}) version: 0x{x}", .{ sbi_impl_str, sbi_impl_id, sbi_implementation_version });

    mm.setupPaging();
}
