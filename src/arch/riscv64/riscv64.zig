const sbi = @import("sbi.zig");
const mm = @import("mm.zig");
const kio = @import("../../kio.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");

pub const VirtualAddress = mm.Sv39VirtualAddress;
pub const PhysicalAddress = mm.Sv39PhysicalAddress;

pub const enableInterrupts = trap.enableInterrupts;
pub const disableInterrupts = trap.disableInterrupts;

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

    kio.info("Starting kara(riscv64)...", .{});
    const sbi_version = sbi.getSpecificationVersion();
    const sbi_version_major = sbi_version >> 24;
    const sbi_version_minor = sbi_version & 0x00FFFFFF;
    const sbi_impl_id = sbi.getImplementationID();
    const sbi_impl_str: []const u8 = if (sbi_impl_id < sbi.sbi_implementations.len)
        sbi.sbi_implementations[sbi_impl_id]
    else
        "Unknown";
    const sbi_implementation_version = sbi.getImplementationVersion();

    kio.info("SBI specification version: {}.{}", .{ sbi_version_major, sbi_version_minor });
    kio.info("SBI implementation: {s} (ID={x}) version: 0x{x}", .{ sbi_impl_str, sbi_impl_id, sbi_implementation_version });

    mm.setupPaging();
}
