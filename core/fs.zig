pub const OpenFlags = packed struct(u64) {
    reserved: u64,
};

pub const OpenMode = packed struct(u64) {
    reserved: u64,
};

pub const DirectoryEntryHeader = extern struct {
    name_size: u32,
    file_type: u32,
    inode: u64,

    // name ...
};
