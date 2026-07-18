//! Documentation for the CPIO format: https://www.systutorials.com/docs/linux/man/5-cpio/

const std = @import("std");
const vfs = @import("vfs.zig");

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

const file_type_mask: u16 = 0o170000;
const file_type_socket: u16 = 0o140000;
const file_type_symbol_link: u16 = 0o120000;
const file_type_regular_file: u16 = 0o100000;
const file_type_block_device: u16 = 0o060000;
const file_type_directory: u16 = 0o040000;
const file_type_character_device: u16 = 0o020000;
const file_type_pipe: u16 = 0o010000;

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

const Record = struct {
    path: []const u8,
    content: []const u8,
    mode: u16,
};

fn readRecord(reader: *std.Io.Reader, record: *Record, header_type: HeaderType) !bool {
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
            record.path = (try reader.take(path_size))[0 .. path_size - 1];
            if (total_header_size % 2 != 0) {
                _ = try reader.take(1);
            }

            const upper_file_size = @shlExact(@as(u32, header.file_size[0]), 16);
            const file_size: u32 = upper_file_size + header.file_size[1];
            record.content = try reader.take(file_size);
            if (file_size % 2 != 0) {
                _ = try reader.take(1);
            }

            record.mode = header.mode;

            return !std.mem.eql(u8, record.path, end_record_name);
        },
        .old_ascii => {
            const header = try reader.takeStruct(OldAsciiHeader, .native);

            // path_size contains '\0' too
            const path_size = try std.fmt.parseInt(usize, &header.full_path_size, 8);
            record.path = (try reader.take(path_size))[0 .. path_size - 1];

            const file_size = try std.fmt.parseInt(usize, &header.file_size, 8);
            record.content = try reader.take(file_size);

            record.mode = try std.fmt.parseInt(u16, &header.mode, 8);

            return !std.mem.eql(u8, record.path, end_record_name);
        },
        .new_ascii, .new_ascii_crc => {
            const calculate_checksum = header_type == .new_ascii_crc;

            const header = try reader.takeStruct(NewAsciiHeader, .native);

            // path_size contains '\0' too
            const path_size = try std.fmt.parseInt(usize, &header.full_path_size, 16);
            const total_header_size = @sizeOf(NewAsciiHeader) + path_size;
            record.path = (try reader.take(path_size))[0 .. path_size - 1];
            if (total_header_size % 4 != 0) {
                _ = try reader.take(4 - total_header_size % 4);
            }

            const file_size = try std.fmt.parseInt(usize, &header.file_size, 16);
            record.content = try reader.take(file_size);
            if (file_size % 4 != 0) {
                _ = try reader.take(4 - file_size % 4);
            }

            record.mode = try std.fmt.parseInt(u16, &header.mode, 16);

            if (calculate_checksum) {
                const expected_checksum = try std.fmt.parseInt(u32, &header.checksum, 16);
                var checksum: u32 = 0;
                for (record.content) |byte| {
                    checksum +%= byte;
                }

                if (checksum != expected_checksum) {
                    return error.ChecksumMismatch;
                }
            }

            return !std.mem.eql(u8, record.path, end_record_name);
        },
    }
}

// TODO: custom errorset instead of std Io error
pub fn readInitramfsArchive(
    gpa: std.mem.Allocator,
    mount_table: *vfs.MountTable,
    cpio_data: []const u8,
) !void {
    var reader = std.Io.Reader.fixed(cpio_data);

    const header_type = try getHeaderType(&reader);

    // The documentation doesn't say anything about this but it's fair to assume that all headers
    // within an archive use the same format and that we don't need to check for this.

    // TODO: permission bits

    // Since the initramfs archive is created with
    // find root | cpio -o > root.cpio
    // all files (except the root dir, in which case the file name is just "root")
    // are prefixed by "root/".

    // Also since find first lists the directory then the entries in the directory the loop below
    // correctly creates the directory first then the entries.

    const prefix = "root";

    var inode_counter: usize = 100;
    var record: Record = undefined;

    while (try readRecord(&reader, &record, header_type)) {
        const file_type = record.mode & file_type_mask;

        // skip root directory
        if (record.path.len == prefix.len) continue;

        std.debug.assert(record.path.len > prefix.len);

        const name_start_idx = if (record.path[prefix.len] == '/') prefix.len + 1 else prefix.len;
        const path_name = record.path[name_start_idx..record.path.len];

        switch (file_type) {
            file_type_regular_file => {
                const file_name = std.fmt.allocPrint(gpa, "/{s}", .{path_name}) catch @panic("Archive file path name too long");
                try vfs.createRegularFile(mount_table, .fromInt(inode_counter), file_name);
                inode_counter += 1;
                // TODO: maybe createRegularFile could return an OpenFile already?

                const open_file = vfs.openFile(mount_table, file_name) catch unreachable;
                _ = open_file.write(record.content, 0) catch @panic("Failed to write content of CPIO archive file");
            },
            file_type_directory => {
                const file_name = std.fmt.allocPrint(gpa, "/{s}", .{path_name}) catch @panic("Archive file path name too long");
                try vfs.createDirectory(mount_table, .fromInt(inode_counter), file_name);
                inode_counter += 1;
            },
            else => {},
        }
    }
}
