//! Documentation for the CPIO format: https://www.systutorials.com/docs/linux/man/5-cpio/

const std = @import("std");

/// Old binary CPIO file header format
const OldBinaryHeader = packed struct {
    magic: u16,
    device: u16,
    inode: u16,
    mode: u16,
    uid: u16,
    gid: u16,
    link_count: u16,
    root_device: u16,
    modified_time: [2]u16,
    name_size: u16,
    file_size: [2]u16,

    const magic_value: u16 = 0o070707;
};

/// SUSv2 ASCII(odc) CPIO file header format
///
///
const OldAsciiHeader = packed struct {
    magic: [6]u8,
    device: [6]u8,
    inode: [6]u8,
    mode: [6]u8,
    uid: [6]u8,
    gid: [6]u8,
    link_count: [6]u8,
    root_device: [6]u8,
    modified_time: [11]u8,
    name_size: [6]u8,
    file_size: [11]u8,

    const magic_value: []const u8 = "070707";
};

/// New SVR4 ASCII format
///
/// All fields are 8 byte hexadecimal values
const NewAsciiHeader = packed struct {
    magic: [6]u8,
    inode: [8]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    link_count: [8]u8,
    modified_time: [8]u8,
    file_size: [8]u8,
    device_major: [8]u8,
    device_minor: [8]u8,
    root_device_major: [8]u8,
    root_device_minor: [8]u8,
    name_size: [8]u8,
    check: [8]u8,

    const magic_value: []const u8 = "070701";
    const magic_value_crc: []const u8 = "070702";
};

const HeaderType = enum {
    old_binary_little_endian,
    old_binary_big_endian,
    old_ascii,
    new_ascii,
    new_ascii_crc,
};

fn getHeaderType(reader: *std.Io.Reader) !HeaderType {
    // try old binary format
    if (try reader.peekInt(u16, .little) == OldBinaryHeader.magic_value)
        return .old_binary_little_endian;

    if (try reader.peekInt(u16, .big) == OldBinaryHeader.magic_value)
        return .old_binary_big_endian;

    const ascii_magic = try reader.peek(6);
    if (std.mem.eql(u8, ascii_magic, OldAsciiHeader.magic_value))
        return .old_ascii;

    if (std.mem.eql(u8, ascii_magic, NewAsciiHeader.magic_value))
        return .new_ascii;

    if (std.mem.eql(u8, ascii_magic, NewAsciiHeader.magic_value_crc))
        return .new_ascii_crc;

    return error.UnknownHeaderType;
}

// TODO: custom errorset instead of std Io error
pub fn readArchive(cpio_data: []const u8) !void {
    var reader = std.Io.Reader.fixed(cpio_data);

    const header = try getHeaderType(&reader);
    std.log.debug("header type: {}", .{header});
}
