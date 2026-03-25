const root = @import("root");
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

export fn initRiscv64(
    hart_id: usize,
    dt_phys: usize,
    root_page_table_phys: usize,
) void {
    // at this point virtual memory is still disabled
    // arch.setupVM();
    // virtual memory has been enabled
    _ = hart_id;
    const KERNEL_PHYS_ADDRESS = 0x80200000;
    const KERNEL_VIRT_ADDRESS = 0xffffffffc0200000;
    const KERNEL_OFFSET = KERNEL_VIRT_ADDRESS - KERNEL_PHYS_ADDRESS;
    const dt_ptr_virt: *void = @ptrFromInt(dt_phys + KERNEL_OFFSET);
    const root_page_table_virt: usize = root_page_table_phys + KERNEL_OFFSET;

    mm.setupPaging(root_page_table_virt);
    root.init(dt_ptr_virt);
}
