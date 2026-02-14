const std = @import("std");
const kio = @import("../../kio.zig");
const csr = @import("csr.zig").CSR;
const sbi = @import("sbi.zig");
const timer = @import("timer.zig");
const devicetree = @import("root").devicetree;
const registers = @import("registers.zig");

const Registers = registers.Registers;

extern fn trapHandlerSupervisor() void;

const TrapVectorBaseAddr = packed struct(u64) {
    mode: Mode,
    base: u62,

    const Mode = enum(u2) {
        direct = 0,
        vectored = 1,
    };
    // 0x80200228
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
    csr.sstatus.setBits(1 << @bitOffsetOf(SStatus, "supervisor_interrupt_enable"));
}

pub fn disableInterrupts() void {
    csr.sstatus.clearBits(1 << @bitOffsetOf(SStatus, "supervisor_interrupt_enable"));
}

pub fn enableInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    csr.sie.setBits(std.math.shl(u64, 1, id));
}

pub fn disableInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    csr.sie.clearBits(std.math.shl(u64, 1, id));
}

pub fn clearPendingInterrupt(id: usize) void {
    std.debug.assert(id < 64);
    csr.sip.clearBits(std.math.shl(u64, 1, id));
}

fn genericExceptionHandler(code: ExceptionCode, pc: u64, status: SStatus, tval: u64, regs: *Registers) void {
    _ = status;
    regs.printGPRs(.err);
    std.log.err("PC=0x{x}", .{pc});
    std.log.err("Trap value: 0x{x}", .{tval});
    @panic(@tagName(code));
}

fn handleException(code: ExceptionCode, pc: u64, status: SStatus, tval: u64, regs: *Registers) void {
    switch (code) {
        .load_page_fault, .instruction_page_fault, .store_or_amo_page_fault => {
            regs.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            std.log.err("Faulting address: 0x{x}", .{tval});
            @panic("Page fault");
        },
        .ecall_u_mode => {
            @panic("TODO");
        },
        .ecall_s_mode => {
            regs.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            std.log.err("Trap value: 0x{x}", .{tval});
            @panic("Environment call from S mode");
        },
        .ecall_m_mode => {
            regs.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            std.log.err("Trap value: 0x{x}", .{tval});
            @panic("Environment call from M mode");
        },
        else => genericExceptionHandler(code, pc, status, tval, regs),
    }
}

fn handleInterrupt(
    code: InterruptCode,
    pc: u64,
    status: SStatus,
    tval: u64,
    frame: *Registers,
) void {
    _ = tval;
    _ = status;
    switch (code) {
        .supervisor_software => {
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Supervisor software interrupt");
        },
        .machine_software => {
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Machine software interrupt");
        },
        .supervisor_timer => {
            timer.tick();
        },
        .machine_timer => {
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Machine timer interrupt");
        },
        .supervisor_external => {
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Supervisor external interrupt");
        },
        .machine_external => {
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Machine external interrupt");
        },
        .counter_overflow => {
            frame.printGPRs(.err);
            std.log.err("PC=0x{x}", .{pc});
            @panic("Counter overflow interrupt");
        },
    }
}

// TODO: REPLACE THIS
const trap_stack_size = 4 * 4096;
var trap_stack: [trap_stack_size]u8 align(16) = undefined;
export var trap_stack_bottom: u64 = undefined;

export fn handleTrap(
    epc: u64,
    cause: TrapCause,
    status: SStatus,
    tval: u64,
    frame: *Registers,
) void {
    if (cause.asynchronous) {
        handleInterrupt(cause.interrupt(), epc, status, tval, frame);
    } else {
        handleException(cause.exception(), epc, status, tval, frame);
    }
}

pub fn initDriver(dt: *const devicetree.DeviceTree, handle: usize) !void {
    _ = dt;
    _ = handle;
    const stvec = TrapVectorBaseAddr.make(
        @intFromPtr(&trapHandlerSupervisor),
        TrapVectorBaseAddr.Mode.direct,
    );

    csr.stvec.write(@bitCast(stvec));
    trap_stack_bottom = @intFromPtr(&trap_stack) + trap_stack_size;
}
