const std = @import("std");

pub const Spinlock = struct {
    const unlocked = 1;
    const locked = 0;

    value: std.atomic.Value(usize) = .init(unlocked),

    pub fn lock(self: *Spinlock) void {
        while (self.value.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Spinlock) void {
        self.value.store(unlocked, .release);
    }
};
