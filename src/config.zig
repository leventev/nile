const Module = struct {
    name: []const u8,
    module: type,
    enabled: bool,
    init_type: ModuleType,

    const ModuleType = union(enum) {
        always_run,
        driver: Driver,
    };

    const Driver = struct {
        compatible: []const []const u8,
    };
};

pub const modules: []const Module = &.{
    .{
        .name = "uart",
        .module = @import("drivers/uart.zig"),
        .enabled = true,
        .init_type = Module.ModuleType{
            .driver = .{
                .compatible = &.{ "ns16550", "ns16550a" },
            },
        },
    },
    .{
        .name = "riscv-cpu-intc",
        .module = @import("arch/riscv64/trap.zig"),
        .enabled = true,
        .init_type = Module.ModuleType{
            .driver = .{
                .compatible = &.{"riscv,cpu-intc"},
            },
        },
    },
    .{
        .name = "riscv-plic",
        .module = @import("arch/riscv64/plic.zig"),
        .enabled = true,
        .init_type = Module.ModuleType{
            .driver = .{
                .compatible = &.{ "sifive,plic-1.0.0", "riscv,plic0" },
            },
        },
    },
};

pub const debug_scheduler: bool = false;
