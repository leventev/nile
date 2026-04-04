const std = @import("std");
const slab_allocator = @import("mem/slab_allocator.zig");
const scheduler = @import("scheduler.zig");
const Process = @import("Process.zig");
const arch = @import("arch/arch.zig");

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
pub fn spawnProcess(
    root_page_table: arch.PageTable,
    parent_pid: ?Process.Id,
    data: []const u8,
) !Process.Id {
    const new_proc_id = processes_available.toggleFirstSet() orelse
        @panic("TODO: No more PIDs available");
    var new_proc = try process_cache.alloc();

    new_proc.id = @enumFromInt(new_proc_id);
    new_proc.parent_id = parent_pid;
    // PID 1 takes over the original root page table
    new_proc.root_page_table = root_page_table;

    var reader = std.Io.Reader.fixed(data);
    const elf_header = std.elf.Header.read(&reader) catch @panic("TODO: elf header error");

    // TODO: REMOVE THIS
    // we only set SUM so that we can write to the PT_LOAD sections,
    // once demand paging is implemented SUM will be set to 0
    @import("arch/riscv64/csr.zig").CSR.sstatus.setBits(1 << @bitOffsetOf(@import("arch/riscv64/trap.zig").SStatus, "supervisor_user_memory_accessable"));

    // TODO: do validation
    var prog_header_it = elf_header.iterateProgramHeadersBuffer(data);
    while (try prog_header_it.next()) |prog_header| {
        if (prog_header.p_type != std.elf.PT_LOAD)
            continue;

        std.log.debug("{}", .{prog_header});
        // TODO: dont ignore .align
        var pages = prog_header.p_memsz / arch.page_size;
        if (prog_header.p_memsz % arch.page_size != 0) {
            pages += 1;
        }

        // TODO: instead of loading the binary like this use demand paging
        new_proc.mapRegion(
            .fromInt(prog_header.p_vaddr),
            pages * arch.page_size,
            .{
                .execute = true,
                .read = true,
                .write = true,
                // .execute = prog_header.p_flags & std.elf.PF_X != 0,
                // .read = prog_header.p_flags & std.elf.PF_R != 0,
                // .write = prog_header.p_flags & std.elf.PF_W != 0,
            },
        ) catch unreachable;

        const ph_data = data[prog_header.p_offset .. prog_header.p_offset + prog_header.p_filesz];
        const mapped_region = (@as([*]u8, @ptrFromInt(prog_header.p_vaddr)))[0..prog_header.p_memsz];
        const file_region = mapped_region[0..prog_header.p_filesz];
        const zeroed_region = mapped_region[prog_header.p_filesz..prog_header.p_memsz];

        @memcpy(file_region, ph_data);
        @memset(zeroed_region, 0);
    }

    new_proc.user_thread_id = try scheduler.newUserThread(elf_header.entry, 0);

    return new_proc.id;
}

pub fn init() void {
    process_cache = slab_allocator.createObjectCache(Process);
    // permanently mark PID 0 as used so first PID allocated is 1
    // TODO: consider having a sentinel Process instead of Thread
    processes_available.unset(0);
}
