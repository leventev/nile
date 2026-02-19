locked: u64 = 0,

const Self = @This();

extern fn __riscv64_lock(lock: *u64) void;
extern fn __riscv64_unlock(lock: *u64) void;

pub fn lock(self: *Self) void {
    __riscv64_lock(&self.locked);
}

pub fn unlock(self: *Self) void {
    __riscv64_unlock(&self.locked);
}
