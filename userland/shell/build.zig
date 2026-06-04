const std = @import("std");

pub fn build(b: *std.Build) void {
    const riscv_f = std.Target.riscv.Feature;
    _ = riscv_f;
    const features_add = [_]std.Target.riscv.Feature{};

    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .cpu_arch = .riscv64,
        .ofmt = .elf,
        .cpu_features_add = std.Target.riscv.featureSet(&features_add),
    });

    // const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const sys = b.dependency("sys", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("sys", sys.module("sys"));

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
