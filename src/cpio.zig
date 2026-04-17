//! Documentation for the CPIO format: https://www.systutorials.com/docs/linux/man/5-cpio/

const std = @import("std");

/// Old binary CPIO file header format
///
/// The file name is padded with '\0' so that the size of the header
/// plus the path name is divisible by 4
const OldBinaryHeader = extern struct {
    magic: u16,
    device: u16,
    inode: u16,
    mode: u16,
    uid: u16,
    gid: u16,
    link_count: u16,
    root_device: u16,
    modified_time: [2]u16,
    full_path_size: u16,
    file_size: [2]u16,

    const magic_value: u16 = 0o070707;
};

/// SUSv2 ASCII (old character or odc) CPIO file header format
///
/// The numeric fields are all ASCII strings containing octal values
/// Unlike the other formats the file name is not padded with '\0'
const OldAsciiHeader = extern struct {
    magic: [6]u8,
    device: [6]u8,
    inode: [6]u8,
    mode: [6]u8,
    uid: [6]u8,
    gid: [6]u8,
    link_count: [6]u8,
    root_device: [6]u8,
    modified_time: [11]u8,
    full_path_size: [6]u8,
    file_size: [11]u8,

    const magic_value: []const u8 = "070707";
};

/// New SVR4 ASCII format
///
/// The numeric fields are all ASCII strings containing hexadecimal values
/// The file name is padded with '\0' so that the size of the header
/// plus the path name is divisible by 4
///
/// If magic contains the value of magic_value_crc then TODO
const NewAsciiHeader = extern struct {
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
    full_path_size: [8]u8,
    checksum: [8]u8,

    const magic_value: []const u8 = "070701";
    const magic_value_crc: []const u8 = "070702";
};

/// At the end of every archive is a special record with this name
const end_record_name = "TRAILER!!!";

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

    const header_type = try getHeaderType(&reader);
    std.log.debug("header type: {}", .{header_type});

    // The documentation doesn't say anything about this but it's fair to assume that all headers
    // within an archive use the same format and that we don't need to check for this.

    var archive_end_reached: bool = false;

    while (!archive_end_reached) {
        switch (header_type) {
            .old_binary_little_endian, .old_binary_big_endian => {
                const endinanness = if (header_type == .old_binary_little_endian)
                    std.builtin.Endian.little
                else
                    std.builtin.Endian.big;

                // TODO: we could do a tiny optimization here by making endianness comptime known
                const header = try reader.takeStruct(OldBinaryHeader, endinanness);

                // path_size contains '\0' too
                const path_size = header.full_path_size;
                const total_header_size = @sizeOf(OldBinaryHeader) + path_size;
                const path: []u8 = (try reader.take(path_size))[0 .. path_size - 1];
                if (total_header_size % 2 != 0) {
                    _ = try reader.take(1);
                }

                const upper_file_size = @shlExact(@as(u32, header.file_size[0]), 16);
                const file_size: u32 = upper_file_size + header.file_size[1];
                const file_contents = try reader.take(file_size);
                _ = file_contents;
                if (file_size % 2 != 0) {
                    _ = try reader.take(1);
                }

                archive_end_reached = std.mem.eql(u8, path, end_record_name);
            },
            .old_ascii => {
                const header = try reader.takeStruct(OldAsciiHeader, .native);

                // path_size contains '\0' too
                const path_size = try std.fmt.parseInt(usize, &header.full_path_size, 8);
                const path: []u8 = (try reader.take(path_size))[0 .. path_size - 1];

                const file_size = try std.fmt.parseInt(usize, &header.file_size, 8);
                const file_contents = try reader.take(file_size);
                _ = file_contents;

                archive_end_reached = std.mem.eql(u8, path, end_record_name);
            },
            .new_ascii, .new_ascii_crc => {
                const calculate_checksum = header_type == .new_ascii_crc;

                const header = try reader.takeStruct(NewAsciiHeader, .native);

                // path_size contains '\0' too
                const path_size = try std.fmt.parseInt(usize, &header.full_path_size, 16);
                const total_header_size = @sizeOf(NewAsciiHeader) + path_size;
                const path: []u8 = (try reader.take(path_size))[0 .. path_size - 1];
                if (total_header_size % 4 != 0) {
                    _ = try reader.take(4 - total_header_size % 4);
                }

                const file_size = try std.fmt.parseInt(usize, &header.file_size, 16);
                const file_contents = try reader.take(file_size);
                if (file_size % 4 != 0) {
                    _ = try reader.take(4 - file_size % 4);
                }

                if (calculate_checksum) {
                    const expected_checksum = try std.fmt.parseInt(u32, &header.checksum, 16);
                    var checksum: u32 = 0;
                    for (file_contents) |byte| {
                        checksum +%= byte;
                    }

                    if (checksum != expected_checksum) {
                        return error.ChecksumMismatch;
                    }
                }

                archive_end_reached = std.mem.eql(u8, path, end_record_name);
            },
        }
    }
}
