const riscv64 = @import("riscv64/riscv64.zig");
comptime {
    _ = riscv64.initRiscv64;
}

const Arch = enum {
    riscv64,
};

const target = Arch.riscv64;

pub const KernelMemoryAddresses = struct {
    higher_half: usize,
    page_descriptors: usize,
    kernel: usize,
    kernel_entry: usize,
    kernel_virtual_offset: usize,
};

pub const kernel_addresses = switch (target) {
    Arch.riscv64 => riscv64.kernel_addresses,
};

pub const enableInterrupts = switch (target) {
    Arch.riscv64 => riscv64.enableInterrupts,
};

pub const disableInterrupts = switch (target) {
    Arch.riscv64 => riscv64.disableInterrupts,
};

pub const ThreadState = switch (target) {
    Arch.riscv64 => riscv64.ThreadState,
};

pub const scheduleNextThread = switch (target) {
    Arch.riscv64 => riscv64.scheduleNextThread,
};

pub const forceScheduleNextThread = switch (target) {
    Arch.riscv64 => riscv64.forceSchedule,
};

pub const setupSoftInterruptThread = switch (target) {
    Arch.riscv64 => riscv64.setupSoftInterruptThread,
};

pub const setupNewGeneralThread = switch (target) {
    Arch.riscv64 => riscv64.setupNewGeneralThread,
};

pub const mapRegion = switch (target) {
    Arch.riscv64 => riscv64.mapRegion,
};

pub const PageTable = switch (target) {
    Arch.riscv64 => riscv64.PageTable,
};

pub const page_size = switch (target) {
    Arch.riscv64 => riscv64.page_size,
};

pub const entries_per_table = switch (target) {
    Arch.riscv64 => riscv64.entries_per_table,
};

pub const copyPageTable = switch (target) {
    Arch.riscv64 => riscv64.copyPageTable,
};

pub const unmapAddressSpace = switch (target) {
    Arch.riscv64 => riscv64.unmapAddressSpace,
};

pub const switchAddressSpace = switch (target) {
    Arch.riscv64 => riscv64.switchAddressSpace,
};

pub const setupPageDescriptors = switch (target) {
    Arch.riscv64 => riscv64.setupPageDescriptors,
};

// TODO: better way to abstract clocks
pub const clock_source = switch (target) {
    Arch.riscv64 => riscv64.clock_source,
};
