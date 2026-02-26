const std = @import("std");
const Process = @import("Process.zig");

var processes: std.DoublyLinkedList(Process) = .{};
var processes_available: std.bit_set.ArrayBitSet(usize, Process.Id) = .initFull();

pub const Error = error{no_available_threads};

fn nextThreadId() Error!Process.Id {
    const process_id_int = processes_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(process_id_int);
}

pub fn init() void {}
