const std = @import("std");
const cfg = @import("src/config.zig");

const userland_programs = .{"shell"};

pub fn build(b: *std.Build) !void {
    // we are targeting riscv64
    const riscv_f = std.Target.riscv.Feature;
    const features_add = [_]std.Target.riscv.Feature{riscv_f.a};

    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .cpu_arch = .riscv64,
        .ofmt = .elf,
        .cpu_features_add = std.Target.riscv.featureSet(&features_add),
    });

    // the user can choose the optimization level
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medany,
        }),
    });

    const build_image_step = b.step("image", "Build the / image from the 'root' directory");

    const sys = b.dependency("sys", .{
        .target = target,
        .optimize = optimize,
    });
    const programs = &.{ "shell", "ls" };

    inline for (programs) |program| {
        const path = try std.fmt.allocPrint(b.allocator, "userland/{s}/{s}.zig", .{ program, program });
        const user_exe = b.addExecutable(.{
            .name = program,
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .code_model = .medany,
            }),
        });
        user_exe.root_module.addImport("sys", sys.module("sys"));
        const user_exe_install = b.addInstallArtifact(user_exe, .{
            .dest_dir = .{
                .override = .{ .custom = "../root" },
            },
        });
        build_image_step.dependOn(&user_exe_install.step);
    }

    exe.root_module.addAssemblyFile(b.path("src/arch/riscv64/start.s"));
    exe.root_module.addAssemblyFile(b.path("src/arch/riscv64/schedule.s"));
    exe.root_module.addAssemblyFile(b.path("src/arch/riscv64/lock.s"));
    exe.setLinkerScript(b.path("linker.ld"));

    // TODO: fix when 0.17 drops
    // https://codeberg.org/ziglang/zig/issues/35473
    const find_command = b.addSystemCommand(&.{ "find", "root" });
    const cpio_command = b.addSystemCommand(&.{ "cpio", "-o", "-F", "src/root.cpio" });
    cpio_command.setStdIn(.{ .lazy_path = find_command.captureStdOut(.{}) });

    build_image_step.dependOn(&cpio_command.step);
    b.getInstallStep().dependOn(build_image_step);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests for the library");
    const run_unit_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_unit_tests.step);

    const qemu = b.addSystemCommand(&.{"qemu-system-riscv64"});
    qemu.addArgs(&.{
        "-machine", "virt",
        // "-bios",    "opensbi/build/platform/generic/firmware/fw_dynamic.bin",
        "-kernel",  "zig-out/bin/nile",
        "-serial",  "stdio",
        "-m",       "128M",
        "-device",  "virtio-gpu",
        "-d",       "int",
        "-d",       "guest_errors",
        "-device",
        "virtio-keyboard",

        // "-d",
        // "int",
        // "-s",       "-S",
    });
    qemu.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the kernel in qemu");
    run_step.dependOn(&qemu.step);
}
