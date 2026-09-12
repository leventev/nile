const std = @import("std");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const Process = @import("Process.zig");
const device = @import("device.zig");

const Thread = @This();

/// ID of the thread. Every thread regardless of purpose has a unique ID.
id: Id,

///
scheduler_list_next: ?*Thread,

kernel_state: *arch.ThreadState,

/// Start of the kernel stack
kernel_stack_top: mm.VirtualAddress,

kernel_stack_size: usize,

/// The type/purpose of the thread.
purpose: Purpose,

pub const Id = enum(usize) {
    _,
    pub const max = 8192;
};

pub const Purpose = union(enum) {
    /// General purpose thread.
    general: General,

    /// A soft interrupt handler is scheduled by the actual interrupt handler.
    soft_interrupt: SoftInterruptHandler,
};

pub const General = struct {
    /// Whether the thread is a user or kernel thread.
    user: ?UserThread,

    process_list_next: ?*Thread,

    /// Which process the thread belongs to.
    owner_process: *Process,

    current_state: State,
    previous_states: StateBuffer,

    pub const UserThread = struct {
        thread_state: *arch.ThreadState,
    };

    ///
    ///             exception
    ///           /
    /// userspace - kernelspace - interrupt - exception
    ///           |             \
    ///           |              exception
    ///           \
    ///            interrupt - exception
    ///
    pub const State = enum(u3) {
        /// Thread is running in user space. Only valid for user threads.
        userspace = 0,

        /// Thread is running in kernel space. In case of user threads this means syscall.
        kernelspace = 1,

        /// The thread got interrupted and is executing inside an interrupt handler.
        interrupt = 2,

        /// The thread cause an exception and is executing inside an exception handler.
        exception = 3,

        /// The current longest state return chain is:
        /// exception -> interrupt -> kernelspace -> userspace
        const max_depth = 3;
    };

    /// Contains the previous states of the Thread.
    pub const StateBuffer = struct {
        buffer: [State.max_depth]State,
        depth: usize,

        /// Push a state to the state buffer.
        pub fn push(self: *StateBuffer, state: State) void {
            std.log.debug("push {} {}", .{ self.depth, state });
            std.debug.assert(self.depth < State.max_depth);
            self.buffer[self.depth] = state;
            self.depth += 1;
        }

        /// Pop a state from the state buffer.
        pub fn pop(self: *StateBuffer) State {
            std.log.debug("pop {}", .{self.depth});
            std.debug.assert(self.depth > 0);
            self.depth -= 1;
            return self.buffer[self.depth];
        }
    };
};

pub const SoftInterruptHandler = struct {
    dev: *device.Device,
    callback: *const fn (dev: *device.Device) void,

    // TODO: run again?

    /// Whether the thread is already queued. Since a driver or drivers could try to queue
    /// the soft interrupt handler multiple times we would need to traverse the running threads
    /// to avoid adding it to the list again.
    state: enum(u2) {
        unqueued,
        queued,
        done,
    },
};

var per_cpu_thread_state: arch.ThreadState = undefined;
var per_cpu_double_exception_thread_state: arch.ThreadState = undefined;

/// Returns which ThreadState the kernel should save the registers into in case of an interrupt
/// based on its' current state.
pub fn effectiveThreadState(self: *Thread) *arch.ThreadState {
    return switch (self.purpose) {
        .soft_interrupt => self.kernel_state,
        .general => |general| switch (general.current_state) {
            .userspace => blk: {
                const user_thread = general.user orelse unreachable;
                break :blk user_thread.thread_state;
            },
            .kernelspace => self.kernel_state,
            .interrupt => &per_cpu_thread_state,
            .exception => &per_cpu_double_exception_thread_state,
        },
    };
}

// TODO:
const trap = @import("arch/riscv64/trap.zig");

/// Returns the stack bottom the kernel should set the stack pointer to in case of an interrupt
/// based on its' current state.
pub fn effectiveThreadStackBottom(self: *Thread) mm.VirtualAddress {
    const kernel_stack_bottom = self.kernel_stack_top.add(self.kernel_stack_size);

    const per_cpu_stack_top = mm.VirtualAddress.fromInt(@intFromPtr(&trap.per_cpu_trap_stack));
    const per_cpu_stack_bottom = per_cpu_stack_top.add(trap.per_cpu_trap_stack_size);

    const double_exception_stack_top = mm.VirtualAddress.fromInt(
        @intFromPtr(&trap.double_exception_trap_stack),
    );
    const double_exception_stack_bottom = double_exception_stack_top.add(
        trap.double_exception_trap_stack_size,
    );

    return switch (self.purpose) {
        .soft_interrupt => per_cpu_stack_bottom,
        .general => |general| switch (general.current_state) {
            .userspace => kernel_stack_bottom,
            .kernelspace => per_cpu_stack_bottom,
            .interrupt => per_cpu_stack_bottom,
            // TODO: ^^^ set UNIQUE stack for exceptions during interrupts
            .exception => double_exception_stack_bottom,
        },
    };
}
