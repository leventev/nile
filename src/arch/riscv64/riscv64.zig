const root = @import("root");
const std = @import("std");
const sbi = @import("sbi.zig");
const riscv64_mm = @import("mm.zig");
const mm = @import("../../mem/mm.zig");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");
pub const ThreadState = @import("registers.zig").ThreadState;
const scheduler = @import("../../scheduler.zig");
const Thread = @import("../../Thread.zig");
const CSR = @import("csr.zig").CSR;
const config = @import("../../config.zig");
pub const Lock = @import("Lock.zig");

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

const kernel_physical_address = 0x80200000;
const kernel_virtual_address = 0xffffffffc0200000;
pub const kernel_virtual_offset = kernel_virtual_address - kernel_physical_address;

fn setupThreadState(
    thread_state: *ThreadState,
    stack_top: mm.VirtualAddress,
    entry_point: mm.VirtualAddress,
    is_user: bool,
) void {
    if (config.debug_scheduler) {
        thread_state.gprs = [_]u64{0xAA_BB_CC_DD_AA_BB_CC_DD} ** ThreadState.gpr_count;
    } else {
        thread_state.gprs = [_]u64{0x00} ** ThreadState.gpr_count;
    }

    thread_state.pc = @intCast(entry_point.asInt());

    thread_state.status = .{
        .executable_memory_read = true,
        .extra_extension_status = .all_off,
        .float_status = .off,
        .state_dirty = false,
        .supervisor_interrupt_enable = false,
        .supervisor_previous_interrupt_enable = is_user,
        .supervisor_previous_privilege = if (is_user) .user else .supervisor,
        .supervisor_user_memory_accessable = true,
        .user_big_endian = false,
        .user_xlen = .x64,
        .vector_status = .off,
        .__reserved1 = 0,
        .__reserved2 = 0,
        .__reserved3 = 0,
        .__reserved4 = 0,
        .__reserved5 = 0,
        .__reserved6 = 0,
        .__reserved7 = 0,
    };

    thread_state.gprs[ThreadState.stack_ptr] = stack_top.asInt();
    thread_state.gprs[ThreadState.global_data_ptr] = @intFromPtr(&__global_pointer);
}

pub fn setupNewGeneralThread(
    thread: *Thread,
    user_stack_bottom_addr: ?mm.VirtualAddress,
    entry_point_addr: mm.VirtualAddress,
) void {
    const kernel_stack_bottom = thread.kernel_stack_top.add(thread.kernel_stack_size);

    // TODO: maybe separate kernel vs user thread
    if (thread.purpose.general.user) |*user| {
        setupThreadState(thread.kernel_state, kernel_stack_bottom, .fromInt(0), false);
        setupThreadState(user.state, user_stack_bottom_addr.?, entry_point_addr, true);
    } else {
        setupThreadState(thread.kernel_state, kernel_stack_bottom, entry_point_addr, false);
    }
}

pub fn setupSoftInterruptThread(thread: *Thread) void {
    const kernel_stack_bottom = thread.kernel_stack_top.add(thread.kernel_stack_size);
    const entry_point = mm.VirtualAddress.fromInt(
        @intFromPtr(thread.purpose.soft_interrupt.callback),
    );
    setupThreadState(thread.kernel_state, kernel_stack_bottom, entry_point, false);

    // TODO:
    thread.kernel_state.gprs[1] = @intFromPtr(&scheduler.forceScheduleNextThread);
}

pub fn scheduleNextThread(thread: *Thread) void {
    const sscratch_value = @intFromPtr(thread.effectiveThreadState());
    if (config.debug_scheduler) {
        std.log.debug("schedule next thread: ID: {} sscratch: 0x{x} purpose: {any}", .{ @intFromEnum(thread.id), sscratch_value, thread.purpose });
        thread.effectiveThreadState().printRegs(.debug);
    }
    CSR.sscratch.write(sscratch_value);
    trap.current_trap_stack_bottom = thread.kernel_stack_top.asInt() + thread.kernel_stack_size;
    timer.resetTimer();
}

extern fn forceSchedule() noreturn;

pub fn forceScheduleNextThread(thread: *Thread) noreturn {
    const sscratch_value = @intFromPtr(
        switch (thread.purpose) {
            .soft_interrupt => thread.kernel_state,
            .general => |general| if (general.user) |user| user.state else thread.kernel_state,
        },
    );

    if (config.debug_scheduler) {
        std.log.debug("force schedule next thread: {} {any}", .{ thread.id, thread.purpose });
        thread.kernel_state.printRegs(.debug);
    }

    CSR.sscratch.write(sscratch_value);
    timer.resetTimer();
    forceSchedule();
}

pub const clock_source = timer.riscv_clock_source;

fn sbiWriteBytes(bytes: []const u8) ?usize {
    const phys_ptr: usize = @intFromPtr(bytes.ptr) - kernel_virtual_offset;
    sbi.debugConsoleWrite(phys_ptr, bytes.len) catch return null;
    return bytes.len;
}

var init_scratch_registers: ThreadState = undefined;

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

    const dt_ptr_virt: *void = @ptrFromInt(dt_phys + kernel_virtual_offset);
    const root_page_table_virt: usize = root_page_table_phys + kernel_virtual_offset;

    const root_page_table = PageTable{ .entries = @ptrFromInt(root_page_table_virt) };

    // set up a temporary sscratch so that if we hit a trap during initialization
    // the exception handler can run
    CSR.sscratch.write(@intFromPtr(&init_scratch_registers));

    riscv64_mm.setupPaging(root_page_table);

    trap.init();
    root.init(root_page_table, dt_ptr_virt);
}
