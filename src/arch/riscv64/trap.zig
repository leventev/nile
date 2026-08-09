const std = @import("std");
const kio = @import("../../kio.zig");
const CSR = @import("csr.zig").CSR;
const sbi = @import("sbi.zig");
const timer = @import("timer.zig");
const devicetree = @import("root").devicetree;
const registers = @import("registers.zig");
const syscalls = @import("syscalls.zig");
const scheduler = @import("../../scheduler.zig");
const plic = @import("../../drivers/int_controller/plic.zig");
const mm = @import("../../mem/mm.zig");
const processes = @import("../../processes.zig");
const arch = @import("../../arch/arch.zig");
const vfs = @import("../../vfs.zig");
const buddy_allocator = @import("../../mem/buddy_allocator.zig");
const riscv64_mm = @import("mm.zig");

const ThreadState = registers.ThreadState;

extern fn trapHandlerSupervisor() void;

const TrapVectorBaseAddr = packed struct(u64) {
    mode: Mode,
    base: u62,

    const Mode = enum(u2) {
        direct = 0,
        vectored = 1,
    };

    fn make(addr: u64, mode: Mode) TrapVectorBaseAddr {
        std.debug.assert(addr & 0b11 == 0);
        return .{
            .mode = mode,
            .base = @intCast(
                std.math.shr(
                    u64,
                    addr,
                    2,
                ),
            ),
        };
    }
};

const TrapCause = packed struct(u64) {
    code: u63,
    asynchronous: bool,

    const Self = @This();

    fn exception(self: Self) ExceptionCode {
        std.debug.assert(!self.asynchronous);
        return @enumFromInt(self.code);
    }

    fn interrupt(self: Self) InterruptCode {
        std.debug.assert(self.asynchronous);
        return @enumFromInt(self.code);
    }
};

const ExceptionCode = enum(u63) {
    instruction_address_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_address_misaligned = 4,
    load_access_fault = 5,
    store_or_amo_address_misaligned = 6,
    store_or_amo_access_fault = 7,
    ecall_u_mode = 8,
    ecall_s_mode = 9,
    ecall_m_mode = 11, // read only fix 0
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_or_amo_page_fault = 15,
    software_check = 18,
    hardware_error = 19,
};

pub const InterruptCode = enum(u63) {
    supervisor_software = 1,
    machine_software = 3,
    supervisor_timer = 5,
    machine_timer = 7,
    supervisor_external = 9,
    machine_external = 11,
    counter_overflow = 13,
};

const MPP = enum(u2) {
    user = 0b00,
    supervisor = 0b01,
    __reserved = 0b10,
    machine = 0b11,
};

const SPP = enum(u1) {
    user = 0,
    supervisor = 1,
};

const VectorStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

const FloatStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

const ExtraExtensionStatus = enum(u2) {
    all_off = 0,
    none_dirt_or_clean = 1,
    none_dirt_some_clean = 2,
    some_dirty = 3,
};

const MPRV = enum(u1) {
    normal = 0,
    behave_like_mpp = 1,
};

const SUM = enum(u1) {
    prohibited = 0,
    permitted = 1,
};

const XLength = enum(u2) {
    x32 = 1,
    x64 = 2,
    x128 = 3,
};

const MStatus = packed struct(u64) {
    __reserved1: u1,
    supervisor_interrupt_enable: bool,
    __reserved2: u1,
    machine_interrupt_enable: bool,
    __reserved3: u1,
    supervisor_previous_interrupt_enable: bool,
    user_big_endian: bool,
    machine_previous_interrupt_enable: bool,
    supervisor_previous_privilege: SPP,
    vector_status: VectorStatus,
    machine_previous_privilege: MPP,
    float_status: FloatStatus,
    extra_extension_status: ExtraExtensionStatus,
    memory_privilege: MPRV,
    supervisor_user_memory_accessable: bool,
    executable_memory_read: bool,
    trap_virtual_memory: bool,
    timeout_wait: bool,
    trap_sret: bool,
    __reserved4: u9,
    user_xlen: XLength,
    supervisor_xlen: XLength,
    supervisor_big_endian: bool,
    machine_big_endian: bool,
    __reserved5: u25,
    state_dirty: bool,
};

pub const SStatus = packed struct(u64) {
    __reserved1: u1,
    supervisor_interrupt_enable: bool,
    __reserved2: u3,
    supervisor_previous_interrupt_enable: bool,
    user_big_endian: bool,
    __reserved3: u1,
    supervisor_previous_privilege: SPP,
    vector_status: VectorStatus,
    __reserved4: u2,
    float_status: FloatStatus,
    extra_extension_status: ExtraExtensionStatus,
    __reserved5: u1,
    supervisor_user_memory_accessable: bool,
    executable_memory_read: bool,
    __reserved6: u12,
    user_xlen: XLength,
    __reserved7: u29,
    state_dirty: bool,

    const Self = @This();
};

pub fn enableInterrupts() void {
    CSR.sstatus.setBits(1 << @bitOffsetOf(SStatus, "supervisor_interrupt_enable"));
}

pub fn disableInterrupts() bool {
    const bit = 1 << @bitOffsetOf(SStatus, "supervisor_interrupt_enable");
    const bits = CSR.sstatus.readAndClearBits(bit);
    return (bits & bit) > 0;
}

pub fn enableInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    CSR.sie.setBits(std.math.shl(u64, 1, id));
}

pub fn disableInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    CSR.sie.clearBits(std.math.shl(u64, 1, id));
}

pub fn clearPendingInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    CSR.sip.clearBits(std.math.shl(u64, 1, id));
}

fn genericExceptionHandler(code: ExceptionCode, tval: u64, state: *ThreadState) void {
    state.printGPRs(.err);
    std.log.err("PC=0x{x}", .{state.pc});
    std.log.err("Trap value: 0x{x}", .{tval});
    @panic(@tagName(code));
}

fn handleException(code: ExceptionCode, tval: u64, state: *ThreadState) void {
    switch (code) {
        .load_page_fault, .instruction_page_fault, .store_or_amo_page_fault => {
            handlePagefault(code, .fromInt(tval), state);
        },
        .ecall_u_mode => {
            syscalls.dispatchSyscall(state);
        },
        .ecall_s_mode => {
            state.printGPRs(.err);
            std.log.err("sstatus={}", .{state.status});
            std.log.err("pc=0x{x}", .{state.pc});
            std.log.err("Trap value: 0x{x}", .{tval});
            @panic("Environment call from S mode");
        },
        .ecall_m_mode => {
            state.printGPRs(.err);
            std.log.err("sstatus={}", .{state.status});
            std.log.err("pc=0x{x}", .{state.pc});
            std.log.err("Trap value: 0x{x}", .{tval});
            @panic("Environment call from M mode");
        },
        else => genericExceptionHandler(code, tval, state),
    }
}

fn handlePagefault(code: ExceptionCode, address: mm.VirtualAddress, state: *ThreadState) void {
    const pagefault_type: mm.PagefaultType = switch (code) {
        .instruction_page_fault => .instruction,
        .load_page_fault => .read,
        .store_or_amo_page_fault => .write,
        else => unreachable,
    };

    const crash = mm.handlePageFault(address, pagefault_type);

    if (crash)
        pagefaultCrash(address, pagefault_type, state);
}

fn pagefaultCrash(
    address: mm.VirtualAddress,
    pagefault_type: mm.PagefaultType,
    state: *ThreadState,
) noreturn {
    const thread = scheduler.getCurrentThread();
    var buff: [256]u8 = undefined;
    const thread_name = if (thread.purpose == .general)
        std.fmt.bufPrint(&buff, "TID: {} PID: {}", .{
            thread.id,
            thread.purpose.general.owner_process.id,
        }) catch unreachable
    else
        std.fmt.bufPrint(&buff, "TID: {}", .{thread.id}) catch unreachable;

    const satp = riscv64_mm.readSATP();

    state.printGPRs(.err);
    std.log.err("sstatus={}", .{state.status});
    std.log.err("pc=0x{x}", .{state.pc});
    std.log.err("faulting address: 0x{x} (root page table phys: 0x{x})", .{
        address.int,
        satp.physical_page_number * arch.page_size,
    });
    std.debug.panic("Page fault ({s}) ({})", .{ thread_name, pagefault_type });
}

var syscall_in_progress = false;

fn handleInterrupt(code: InterruptCode, tval: u64, state: *ThreadState) void {
    _ = tval;
    switch (code) {
        .supervisor_software => {
            state.printGPRs(.err);
            std.log.err("PC=0x{x}", .{state.pc});
            @panic("Supervisor software interrupt");
        },
        .machine_software => {
            state.printGPRs(.err);
            std.log.err("PC=0x{x}", .{state.pc});
            @panic("Machine software interrupt");
        },
        .supervisor_timer => {
            timer.tick();
        },
        .machine_timer => {
            state.printGPRs(.err);
            std.log.err("PC=0x{x}", .{state.pc});
            @panic("Machine timer interrupt");
        },
        .supervisor_external => {
            if (syscall_in_progress) @panic("syscall received while in a syscall handler");
            syscall_in_progress = true;
            plic.handleInterrupt();
            syscall_in_progress = false;
        },
        .machine_external => {
            state.printGPRs(.err);
            std.log.err("PC=0x{x}", .{state.pc});
            @panic("Machine external interrupt");
        },
        .counter_overflow => {
            state.printGPRs(.err);
            std.log.err("PC=0x{x}", .{state.pc});
            @panic("Counter overflow interrupt");
        },
    }
}

export fn handleTrap(state: *ThreadState, cause: TrapCause, tval: u64) void {
    if (cause.asynchronous) {
        handleInterrupt(cause.interrupt(), tval, state);
    } else {
        handleException(cause.exception(), tval, state);
    }
}

// // TODO: REPLACE THIS
// AND PAGE GUARD !!!!!!!!!!!!!!!!!!!!!!!!!
pub const trap_stack_size = 12 * 4096;
pub var trap_stack: [trap_stack_size]u8 align(16) = undefined;

pub var trap_regs: ThreadState = undefined;

pub export var current_trap_stack_bottom: u64 = undefined;

pub fn init() void {
    const stvec = TrapVectorBaseAddr.make(
        @intFromPtr(&trapHandlerSupervisor),
        TrapVectorBaseAddr.Mode.direct,
    );

    CSR.sscratch.write(@intFromPtr(&trap_regs));
    current_trap_stack_bottom = @intFromPtr(&trap_stack) + trap_stack_size;

    CSR.stvec.write(@bitCast(stvec));
}
