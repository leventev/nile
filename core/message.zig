const std = @import("std");

const Alignment = std.mem.Alignment;

pub const message_magic: u16 = 0xa67a;
// TODO: very arbitrarly chosen. maybe there is a nicer way to only have one magic value, and let
// the message be a subcase of that
pub const message_array_magic: u16 = 0x937d;

/// A message is just an array of bytes. The first byte of that array is the message type, the rest
/// of the array's bytes are interpreted based on this. The message type has an alignment of 1.
pub const MessageType = enum(u8) {
    /// Nothing. It has a size of zero.
    none = 0,

    /// A single u8 follows the message type.
    uint8 = 1,

    /// A single u16 follows the message type.
    uint16 = 2,

    /// A single u32 follows the message type.
    uint32 = 3,

    /// A single u64 follows the message type.
    uint64 = 4,

    /// A single u8 follows the message type.
    int8 = 5,

    /// A single u16 follows the message type.
    int16 = 6,

    /// A single u32 follows the message type.
    int32 = 7,

    /// A single u64 follows the message type.
    int64 = 8,

    /// The zig type corresponding to the message type.
    pub fn Type(self: MessageType) type {
        return switch (self) {
            .none => void,
            .uint8 => u8,
            .uint16 => u16,
            .uint32 => u32,
            .uint64 => u64,
            .int8 => i8,
            .int16 => i16,
            .int32 => i32,
            .int64 => i64,
        };
    }

    /// Alignment of the message payload.
    pub fn alignment(comptime self: MessageType) Alignment {
        return Alignment.of(self.Type());
    }

    /// Size of the message payload.
    pub fn size(comptime self: MessageType) usize {
        return @sizeOf(self.Type());
    }

    const magic_size = @sizeOf(@TypeOf(message_magic));
    const minimum_message_size = magic_size + @sizeOf(MessageType);

    /// Try to read the expected message type from the provided buffer.
    /// Buffer must be aligned to a 2 byte address.
    /// Prepends the message with the magic value too.
    pub fn readWithMagic(
        comptime expected: MessageType,
        buffer: []const u8,
    ) ?expected.Type() {
        if (!Alignment.of(u16).check(@intFromPtr(buffer.ptr)))
            return null;

        if (buffer.len < minimum_message_size)
            return null;

        const magic_ptr: *const u16 = @ptrCast(@alignCast(buffer.ptr));
        if (magic_ptr.* != message_magic)
            return null;

        return read(expected, buffer[magic_size..]);
    }

    /// Try to read the expected message type from the provided buffer.
    /// Buffer must be aligned to a 2 byte address.
    pub fn read(comptime expected: MessageType, buffer: []const u8) ?expected.Type() {
        if (!Alignment.of(u16).check(@intFromPtr(buffer.ptr)))
            return null;

        const payload_start = expected.alignment().forward(
            @intFromPtr(buffer.ptr) + @sizeOf(MessageType),
        );
        const padded_header_size = payload_start - @intFromPtr(buffer.ptr);
        const total_size = padded_header_size + expected.size();
        if (buffer.len < total_size)
            return null;

        const message_type: *const MessageType = @ptrCast(buffer.ptr);
        if (message_type.* != expected)
            return null;

        const ptr: *const expected.Type() = @ptrFromInt(payload_start);
        return ptr.*;
    }

    /// Try to write the expected message type to the provided buffer.
    /// Buffer must be aligned to a 2 byte address.
    /// Prepends the message with the magic value too.
    pub fn writeWithMagic(
        comptime message_type: MessageType,
        value: message_type.Type(),
        buffer: []u8,
    ) ?[]const u8 {
        if (!Alignment.of(u16).check(@intFromPtr(buffer.ptr)))
            return null;

        if (buffer.len < minimum_message_size)
            return null;

        const magic_ptr: *u16 = @ptrCast(@alignCast(buffer.ptr));
        magic_ptr.* = message_magic;

        const message = write(message_type, value, buffer[magic_size..]) orelse return null;
        return buffer[0 .. magic_size + message.len];
    }

    /// Try to write the expected message type to the provided buffer.
    /// Buffer must be aligned to a 2 byte address.
    pub fn write(
        comptime message_type: MessageType,
        value: message_type.Type(),
        buffer: []u8,
    ) ?[]const u8 {
        if (!Alignment.of(u16).check(@intFromPtr(buffer.ptr)))
            return null;

        const payload_start = message_type.alignment().forward(
            @intFromPtr(buffer.ptr) + @sizeOf(MessageType),
        );
        const padded_header_size = payload_start - @intFromPtr(buffer.ptr);
        const total_size = padded_header_size + message_type.size();
        if (buffer.len < total_size)
            return null;

        const message_type_ptr: *MessageType = @ptrCast(@alignCast(buffer.ptr));
        message_type_ptr.* = message_type;

        for (@sizeOf(MessageType)..padded_header_size) |i|
            buffer[i] = 0;

        const ptr: *message_type.Type() = @ptrFromInt(payload_start);
        ptr.* = value;
        return buffer[0..total_size];
    }

    const ArrayCountType = u16;

    pub fn readArray(
        comptime expected: MessageType,
        buffer: []const u8,
    ) ?[]const expected.Type() {
        if (!Alignment.of(u16).check(@intFromPtr(buffer.ptr)))
            return null;

        if (buffer.len < 2 * @sizeOf(u16) + @sizeOf(MessageType))
            return null;

        var ptr: usize = @intFromPtr(buffer.ptr);

        const magic_ptr: *const u16 = @ptrFromInt(ptr);
        if (magic_ptr.* != message_array_magic)
            return null;
        ptr += @sizeOf(u16);

        const message_type_ptr: *const MessageType = @ptrFromInt(ptr);
        if (message_type_ptr.* != expected)
            return null;

        ptr = std.mem.Alignment.of(ArrayCountType).forward(ptr + @sizeOf(MessageType));

        const element_count = @as(*const ArrayCountType, @ptrFromInt(ptr)).*;
        ptr += @sizeOf(ArrayCountType);

        const arr_start = expected.alignment().forward(ptr);

        if (arr_start + element_count * expected.size() > @intFromPtr(buffer.ptr) + buffer.len)
            return null;
        const arr_ptr: [*]const expected.Type() = @ptrFromInt(arr_start);

        return arr_ptr[0..element_count];
    }

    // TODO: partial writes
    pub fn writeArray(
        comptime element_type: MessageType,
        values: []const element_type.Type(),
        buffer: []u8,
    ) ?[]u8 {
        if (!Alignment.of(u16).check(@intFromPtr(buffer.ptr)))
            return null;

        if (buffer.len < 2 * @sizeOf(u16) + @sizeOf(MessageType))
            return null;

        const start: usize = @intFromPtr(buffer.ptr);
        var ptr = start;

        const magic_ptr: *u16 = @ptrFromInt(ptr);
        magic_ptr.* = message_array_magic;
        ptr += @sizeOf(u16);

        const message_type_ptr: *MessageType = @ptrFromInt(ptr);
        message_type_ptr.* = element_type;
        ptr = std.mem.Alignment.of(ArrayCountType).forward(ptr + @sizeOf(MessageType));

        const element_count_ptr: *ArrayCountType = @ptrFromInt(ptr);
        element_count_ptr.* = @truncate(values.len);
        ptr += @sizeOf(ArrayCountType);

        const arr_start = element_type.alignment().forward(ptr);
        const end = arr_start + values.len * element_type.size();

        if (end > @intFromPtr(buffer.ptr) + buffer.len)
            return null;

        const arr_ptr: [*]element_type.Type() = @ptrFromInt(arr_start);
        @memcpy(arr_ptr[0..values.len], values);

        return buffer[0 .. end - start];
    }

    pub fn arrayRequiredSizeForward(
        comptime element_type: MessageType,
        count: usize,
        address: usize,
    ) usize {
        // address must be aligned to u16
        std.debug.assert(address % @sizeOf(u16) == 0);
        // TODO: maybe make check whether address will overflow
        const type_addr = Alignment.of(MessageType).forward(address + @sizeOf(u16));
        const cnt_addr = Alignment.of(ArrayCountType).forward(type_addr + @sizeOf(MessageType));
        const arr_addr = element_type.alignment().forward(cnt_addr + @sizeOf(ArrayCountType));
        const arr_end_addr = arr_addr + count * element_type.size();
        return arr_end_addr - address;
    }

    pub fn arrayRequiredSizeBackwards(
        comptime element_type: MessageType,
        count: usize,
        address: usize,
    ) usize {
        // TODO: maybe make check whether address will underflow
        const arr_end_addr = element_type.alignment().backward(address);
        const arr_addr = arr_end_addr - count * element_type.size();
        const cnt_addr = Alignment.of(ArrayCountType).backward(arr_addr - @sizeOf(ArrayCountType));
        const type_addr = Alignment.of(MessageType).backward(cnt_addr - @sizeOf(MessageType));
        const magic_start = Alignment.of(u16).backward(type_addr - @sizeOf(u16));
        return address - magic_start;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const eql = std.mem.eql;

// TODO: tests for size calculating functions once all are written

test "basic message" {
    var buff: [256]u8 = undefined;
    const void_buff = MessageType.none.writeWithMagic({}, &buff).?;
    try expectEqual({}, MessageType.none.readWithMagic(void_buff));
    try expectEqual(MessageType.minimum_message_size, void_buff.len);

    const u8_buff = MessageType.uint8.writeWithMagic(12, &buff).?;
    try expectEqual(12, MessageType.uint8.readWithMagic(u8_buff));

    const u8_buff_2 = MessageType.uint8.write(193, &buff).?;
    try expectEqual(193, MessageType.uint8.read(u8_buff_2));

    const i16_buff = MessageType.int16.writeWithMagic(-6237, &buff).?;
    try expectEqual(-6237, MessageType.int16.readWithMagic(i16_buff));

    const i16_buff_2 = MessageType.int16.write(-25830, &buff).?;
    try expectEqual(-25830, MessageType.int16.read(i16_buff_2));

    const i32_buff = MessageType.int32.write(-30_450_393, &buff).?;
    try expectEqual(-30_450_393, MessageType.int32.read(i32_buff));

    const u64_buff = MessageType.uint64.writeWithMagic(0xab_cd_ef_12_34, &buff).?;
    try expectEqual(0xab_cd_ef_12_34, MessageType.uint64.readWithMagic(u64_buff));
}

test "array message" {
    var buff: [256]u8 = undefined;
    const void_buff = MessageType.none.writeArray(&.{}, &buff).?;
    try expect(eql(void, MessageType.none.readArray(void_buff).?, &.{}));
    try expectEqual(@sizeOf(u16) + @sizeOf(MessageType) + 1 + @sizeOf(u16), void_buff.len);

    const u8_buff = MessageType.uint8.writeArray("hello world!", &buff) orelse unreachable;
    try expect(eql(u8, MessageType.uint8.readArray(u8_buff).?, "hello world!"));

    const u8_buff_2 = MessageType.uint8.writeArray("hello world!!", &buff) orelse unreachable;
    try expect(eql(u8, MessageType.uint8.readArray(u8_buff_2).?, "hello world!!"));

    const u16_buff = MessageType.uint16.writeArray(&.{ 9, 385, 1499, 0, 1 }, &buff) orelse unreachable;
    try expect(eql(u16, MessageType.uint16.readArray(u16_buff).?, &.{ 9, 385, 1499, 0, 1 }));

    const i32_buff = MessageType.int32.writeArray(&.{ 1_000_000, 123 }, &buff) orelse unreachable;
    try expect(eql(i32, MessageType.int32.readArray(i32_buff).?, &.{ 1_000_000, 123 }));

    const u64_buff = MessageType.uint64.writeArray(&.{0xff_ff_ff_ff_34}, &buff) orelse unreachable;
    try expect(eql(u64, MessageType.uint64.readArray(u64_buff).?, &.{0xff_ff_ff_ff_34}));
}
