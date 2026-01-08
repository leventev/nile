id: Id,
level: Level,

pub const Id = enum(usize) {
    _,
    pub const max = 8192;
};

pub const Level = enum {
    kernel,
    user,
};
