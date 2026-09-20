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
const Thread = @import("../../Thread.zig");
const riscv64 = @import("riscv64.zig");
const config = @import("../../config.zig");

const ThreadState = registers.ThreadState;
const SStatus = registers.SStatus;

extern fn trapHandlerSupervisor() void;

const TrapVectorBaseAddress = packed struct(u64) {
    mode: Mode,
    base: u62,

    const Mode = enum(u2) {
        direct = 0,
        vectored = 1,
    };

    fn make(addr: u64, mode: Mode) TrapVectorBaseAddress {
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
        // std.log.debug("hello {}", .{self.code});
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

    mm.handlePagefault(pagefault_type, address, state);
}

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
            plic.handleInterrupt();
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
    // TODO: handle before the scheduler has been initialized
    {
        const current_thread = scheduler.getCurrentThread();

        std.log.debug("trap begin TID: {}", .{@intFromEnum(current_thread.id)});
    }

    if (cause.asynchronous) {
        handleInterrupt(cause.interrupt(), tval, state);
    } else {
        handleException(cause.exception(), tval, state);
    }

    {
        const next_thread = scheduler.getCurrentThread();
        std.log.debug("trap return {}", .{@intFromEnum(next_thread.id)});
    }

    // TODO: ONLY RESET WHEN NECESSARY
    timer.resetTimer();
}

pub fn init() void {
    const stvec = TrapVectorBaseAddress.make(
        @intFromPtr(&trapHandlerSupervisor),
        TrapVectorBaseAddress.Mode.direct,
    );

    CSR.stvec.write(@bitCast(stvec));
}
