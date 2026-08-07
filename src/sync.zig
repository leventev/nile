const std = @import("std");
const Thread = @import("Thread.zig");
const arch = @import("arch/arch.zig");
const scheduler = @import("scheduler.zig");

pub const Spinlock = struct {
    const unlocked_value = 1;
    const locked_value = 0;

    value: std.atomic.Value(usize),

    pub const unlocked = Spinlock{ .value = .init(unlocked_value) };

    pub fn lockInterrupt(self: *Spinlock) bool {
        const interrupts_enabled = arch.disableInterrupts();
        self.lock();

        return interrupts_enabled;
    }

    pub fn lock(self: *Spinlock) void {
        while (self.value.cmpxchgWeak(unlocked_value, locked_value, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Spinlock) void {
        self.value.store(unlocked_value, .release);
    }

    pub fn unlockInterrupt(self: *Spinlock, interrupts_enabled: bool) void {
        self.unlock();
        if (interrupts_enabled) arch.enableInterrupts();
    }
};

pub const Semaphore = struct {
    spinlock: Spinlock,
    available_resources: usize,
    waitlist: ?*Waiter,

    pub const default = Semaphore{
        .spinlock = .unlocked,
        .available_resources = 0,
        .waitlist = null,
    };

    const Waiter = struct {
        thread: *Thread,
        next: ?*Waiter,
        should_release: bool,
    };

    pub fn sub(self: *Semaphore) void {
        const ints_enabled = self.spinlock.lockInterrupt();
        defer self.spinlock.unlockInterrupt(ints_enabled);

        if (self.available_resources > 0) {
            self.available_resources -= 1;
        } else {
            const current_thread = scheduler.getCurrentThread();

            var wait_list_ptr = &self.waitlist;
            while (wait_list_ptr.*) |waiter| : (wait_list_ptr = &waiter.next) {}

            var this_waiter: Waiter = .{
                .next = null,
                .thread = current_thread,
                .should_release = false,
            };

            wait_list_ptr.* = &this_waiter;

            while (true) {
                self.spinlock.unlock();
                arch.forceScheduleNextThread();
                self.spinlock.lock();

                if (this_waiter.should_release)
                    return;
            }
        }
    }

    pub fn add(self: *Semaphore) void {
        const ints_enabled = self.spinlock.lockInterrupt();
        defer self.spinlock.unlockInterrupt(ints_enabled);

        if (self.waitlist) |head| {
            self.waitlist = head.next;
            head.should_release = true;
        } else {
            self.available_resources += 1;
        }
    }
};
