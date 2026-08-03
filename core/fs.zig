pub const OpenFlags = packed struct(u64) {
    reserved: u64,
};

pub const OpenMode = packed struct(u64) {
    reserved: u64,
};

pub const DirectoryEntry = extern struct {
    name_size: u32,
    type: u32,
    inode: u64,

    // name ...
};
