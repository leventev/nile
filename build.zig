const std = @import("std");
const cfg = @import("src/config.zig");

pub fn build(b: *std.Build) void {
    // we are targeting riscv64
    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .cpu_arch = .riscv64,
        .ofmt = .elf,
    });

    // the user can choose the optimization level
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        }),
    });

    exe.addAssemblyFile(b.path("src/arch/riscv64/start.s"));
    exe.addAssemblyFile(b.path("src/arch/riscv64/trap.s"));
    exe.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(exe);

    const qemu = b.addSystemCommand(&.{"qemu-system-riscv64"});
    qemu.addArgs(&.{
        "-machine", "virt",
        "-bios",    "opensbi/build/platform/generic/firmware/fw_dynamic.bin",
        "-kernel",  "zig-out/bin/nile",
        "-serial",  "stdio",
        "-m",
        "128M",
        // "-d",       "int",
    });
    qemu.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the kernel in qemu");
    run_step.dependOn(&qemu.step);
}
