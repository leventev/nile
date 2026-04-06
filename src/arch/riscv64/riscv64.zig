const root = @import("root");
const std = @import("std");
const sbi = @import("sbi.zig");
const riscv64_mm = @import("mm.zig");
const mm = @import("../../mem/mm.zig");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");
pub const Registers = @import("registers.zig").Registers;
const scheduler = @import("../../scheduler.zig");
const Thread = @import("../../Thread.zig");
const CSR = @import("csr.zig").CSR;
const config = @import("../../config.zig");
pub const Lock = @import("Lock.zig");

pub const VirtualAddress = riscv64_mm.Sv39VirtualAddress;
pub const PhysicalAddress = riscv64_mm.Sv39PhysicalAddress;

pub const enableInterrupts = trap.enableInterrupts;
pub const disableInterrupts = trap.disableInterrupts;

pub const switchAddressSpace = riscv64_mm.switchAddressSpace;
pub const unmapAddressSpace = riscv64_mm.unmapAddressSpace;
pub const copyPageTable = riscv64_mm.copyPageTable;
pub const mapRegion = riscv64_mm.mapRegion;
pub const PageTable = riscv64_mm.PageTable;

pub const page_size = riscv64_mm.page_size;
pub const entries_per_table = riscv64_mm.entries_per_table;

extern const __global_pointer: ?void;

const KERNEL_PHYS_ADDRESS = 0x80200000;
const KERNEL_VIRT_ADDRESS = 0xffffffffc0200000;
const KERNEL_OFFSET = KERNEL_VIRT_ADDRESS - KERNEL_PHYS_ADDRESS;

pub fn setupNewThread(thread: *Thread, entry_point_addr: usize, stack_top: usize, user: bool) void {
    if (config.debug_scheduler) {
        thread.registers.gprs = [_]u64{0xAA_BB_CC_DD_AA_BB_CC_DD} ** Registers.gpr_count;
    } else {
        thread.registers.gprs = [_]u64{0x00} ** Registers.gpr_count;
    }

    thread.registers.pc = @intCast(entry_point_addr);
    // TODO: maybe dont copy sstatus?
    thread.registers.status = @bitCast(CSR.sstatus.read());
    if (user) {
        thread.registers.status.supervisor_previous_privilege = .user;
    } else {
        thread.registers.status.supervisor_previous_privilege = .supervisor;
    }
    thread.registers.gprs[Registers.stack_ptr] = @intCast(stack_top);
    thread.registers.gprs[Registers.global_data_ptr] = @intFromPtr(&__global_pointer);
}

pub fn scheduleNextThread(thread: *Thread) void {
    if (config.debug_scheduler) {
        std.log.debug("schedule next thread: {}", .{thread.id});
        thread.registers.printRegs(.debug);
    }
    CSR.sscratch.write(@intFromPtr(&thread.registers));
    timer.resetTimer();
}

pub const clock_source = timer.riscv_clock_source;

fn sbiWriteBytes(bytes: []const u8) ?usize {
    const phys_ptr: usize = @intFromPtr(bytes.ptr) - KERNEL_OFFSET;
    sbi.debugConsoleWrite(phys_ptr, bytes.len) catch return null;
    return bytes.len;
}

var init_scratch_registers: Registers = undefined;

export fn initRiscv64(
    hart_id: usize,
    dt_phys: usize,
    root_page_table_phys: usize,
) noreturn {
    _ = hart_id;

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

    const dt_ptr_virt: *void = @ptrFromInt(dt_phys + KERNEL_OFFSET);
    const root_page_table_virt: usize = root_page_table_phys + KERNEL_OFFSET;

    const root_page_table = PageTable{ .entries = @ptrFromInt(root_page_table_virt) };

    // set up a temporary sscratch so that if we hit a trap during initialization
    // the exception handler can run
    CSR.sscratch.write(@intFromPtr(&init_scratch_registers));

    riscv64_mm.setupPaging(root_page_table);
    root.init(root_page_table, dt_ptr_virt);
}
