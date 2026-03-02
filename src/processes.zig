const std = @import("std");
const slab_allocator = @import("mem/slab_allocator.zig");
const scheduler = @import("scheduler.zig");
const Process = @import("Process.zig");

const log = std.log.scoped(.processes);

var processes: std.DoublyLinkedList(Process) = .{};
var processes_available: std.bit_set.ArrayBitSet(usize, Process.Id.max) = .initFull();

var process_cache: slab_allocator.ObjectCache(Process) = .{};

pub const Error = error{no_available_threads};

fn nextProcessId() Error!Process.Id {
    const process_id_int = processes_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(process_id_int);
}

// TODO
pub fn spawnProcess(parent_pid: ?Process.Id, data: []const u8) !Process.Id {
    const new_proc_id = processes_available.toggleFirstSet() orelse @panic("TODO: No more PIDs available");
    var new_proc = try process_cache.alloc();

    new_proc.id = @enumFromInt(new_proc_id);
    new_proc.parent_id = parent_pid;
    // new_proc.user_thread_id = try scheduler.newUserThread();

    var reader = std.Io.Reader.fixed(data);
    const elf_header = std.elf.Header.read(&reader) catch @panic("TODO: elf header error");

    // TODO: do validation
    var prog_header_it = elf_header.iterateProgramHeadersBuffer(data);
    while (try prog_header_it.next()) |prog_header| {
        log.debug("{any}", .{prog_header});
    }

    return new_proc.id;
}

pub fn init() void {
    process_cache = slab_allocator.createObjectCache(Process);
    // permanently mark PID 0 as used so first PID allocated is 1
    // TODO: consider having a sentinel Process instead of Thread
    processes_available.unset(0);
}
