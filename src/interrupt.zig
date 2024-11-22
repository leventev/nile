// TODO: maybe support multiple interrupt controllers?

pub const InterruptController = struct {
    enableInterrupt: *const fn (int_num: usize) Error!void,
    disableInterrupt: *const fn (int_num: usize) Error!void,
    setPriority: *const fn (int_num: usize, priority: usize) Error!void,
    getPriority: *const fn (int_num: usize) Error!usize,
    setHandler: *const fn (int_num: usize, handler: *const fn () void) Error!void,

    pub const Error = error{
        NoController,
        AlreadyRegistered,
        InvalidInterruptID,
        InvalidPriority,
        ControllerInternalError,
    };
};

var interruptController: ?InterruptController = null;

pub fn registerInterruptController(controller: InterruptController) InterruptController.Error!void {
    if (interruptController != null)
        return error.AlreadyRegistered;

    interruptController = controller;
}

pub fn enableInterrupt(int_num: usize) InterruptController.Error!void {
    const controller = interruptController orelse
        return error.NoController;

    return controller.enableInterrupt(int_num);
}

pub fn disableInterrupt(int_num: usize) InterruptController.Error!void {
    const controller = interruptController orelse
        return error.NoController;

    return controller.disableInterrupt(int_num);
}

pub fn setPriority(int_num: usize, priority: usize) InterruptController.Error!void {
    const controller = interruptController orelse
        return error.NoController;

    return controller.setPriority(int_num, priority);
}

pub fn setHandler(int_num: usize, handler: *const fn () void) InterruptController.Error!void {
    const controller = interruptController orelse
        return error.NoController;

    return controller.setHandler(int_num, handler);
}
