// TODO: maybe support multiple interrupt controllers?

const std = @import("std");
const device = @import("device.zig");
const slab_allocator = @import("mem/slab_allocator.zig");

const Device = device.Device;

pub const InterruptController = struct {
    max_interrupt: usize,
    enableInterrupt: *const fn (int_num: usize) void,
    disableInterrupt: *const fn (int_num: usize) void,
    dumpPendingInterrupts: *const fn () void,
    dumpEnabledInterrupts: *const fn () void,

    pub const Error = error{
        NoController,
        AlreadyRegistered,
        InvalidInterruptID,
    };
};

var interrupt_controller: ?InterruptController = null;

const InterruptHandler = struct {
    owner: *Device,
    interrupt_number: usize,
    handle: *const fn (dev: *Device) void,
    call_count: usize,
    next: ?*InterruptHandler,
};

// TODO: very temporary solution until we get the GPA working
var interrupt_handlers: ?*InterruptHandler = null;
var interrupt_handler_cache: slab_allocator.ObjectCache(InterruptHandler) = undefined;

pub fn registerInterruptController(controller: InterruptController) InterruptController.Error!void {
    if (interrupt_controller != null)
        return error.AlreadyRegistered;

    interrupt_controller = controller;
    interrupt_handler_cache = slab_allocator.createObjectCache(InterruptHandler);
}

pub fn enableInterrupt(int_num: usize) InterruptController.Error!void {
    const controller = interrupt_controller orelse
        return error.NoController;

    if (int_num > controller.max_interrupt)
        return error.InvalidInterruptID;

    controller.enableInterrupt(int_num);
}

pub fn disableInterrupt(int_num: usize) InterruptController.Error!void {
    const controller = interrupt_controller orelse
        return error.NoController;

    if (int_num > controller.max_interrupt)
        return error.InvalidInterruptID;

    controller.disableInterrupt(int_num);
}

pub fn dumpPendingInterrupts() void {
    const controller = interrupt_controller orelse @panic("TODO");

    controller.dumpPendingInterrupts();
}

pub fn dumpEnabledInterrupts() void {
    const controller = interrupt_controller orelse @panic("TODO");

    controller.dumpEnabledInterrupts();
}

pub fn setHandler(int_num: usize, handle: *const fn (dev: *Device) void, dev: *Device) void {
    var next_ptr = &interrupt_handlers;
    while (next_ptr.*) |handler| : (next_ptr = &handler.next) {}

    var new_handler = interrupt_handler_cache.alloc() catch @panic("Failed to alloc");
    new_handler.interrupt_number = int_num;
    new_handler.handle = handle;
    new_handler.owner = dev;
    new_handler.call_count = 0;
    new_handler.next = null;

    next_ptr.* = new_handler;
}

pub fn dispatchInterruipt(int_num: usize) void {
    var next_ptr = &interrupt_handlers;
    while (next_ptr.*) |handler| : (next_ptr = &handler.next) {
        if (handler.interrupt_number == int_num) {
            handler.handle(handler.owner);
            handler.call_count += 1;
        }
    }
}
