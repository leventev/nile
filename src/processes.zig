const std = @import("std");
const slab_allocator = @import("mem/slab_allocator.zig");
const scheduler = @import("scheduler.zig");
const Process = @import("Process.zig");
const Thread = @import("Thread.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const vfs = @import("vfs.zig");

const log = std.log.scoped(.processes);

var running_processes: std.DoublyLinkedList = .{};
var processes_available: std.bit_set.ArrayBitSet(usize, Process.Id.max) = .initFull();

var process_cache: slab_allocator.ObjectCache(Process) = .{};

pub const Error = error{no_available_threads};

fn nextProcessId() Error!Process.Id {
    const process_id_int = processes_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(process_id_int);
}

// TODO
pub fn spawnInitProcess(
    root_page_table: arch.PageTable,
    parent_pid: ?Process.Id,
    data: []const u8,
    mount_table: *vfs.MountTable,
) !*Process {
    const new_proc_id = nextProcessId() catch @panic("TODO: this is pid 1 anyways but handle error");
    std.debug.assert(@intFromEnum(new_proc_id) == 1);
    var new_proc = try process_cache.alloc();

    new_proc.id = new_proc_id;
    new_proc.parent_id = parent_pid;
    new_proc.mount_table = mount_table;
    // PID 0 owns root_page_table and it only contains the kernel higher half mappings
    // we copy it for PID 1
    new_proc.root_page_table = try mm.clonePageTable(root_page_table);

    arch.switchAddressSpace(new_proc.root_page_table);

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

        // TODO: error
        std.debug.assert(prog_header.p_memsz > 0);
        const virt_last_byte_addr = prog_header.p_vaddr + prog_header.p_memsz - 1;
        const virt_start_page_num = prog_header.p_vaddr / arch.page_size;
        const virt_end_page_num = virt_last_byte_addr / arch.page_size;
        const page_count = virt_end_page_num - virt_start_page_num + 1;

        std.debug.assert(
            prog_header.p_vaddr % prog_header.p_align == prog_header.p_offset % prog_header.p_align,
        );

        // TODO: do additional checking to make sure regions dont overlap
        const start_page_addr = virt_start_page_num * arch.page_size;

        // TODO: instead of loading the binary like this use demand paging
        try new_proc.mapRegion(
            .fromInt(start_page_addr),
            page_count * arch.page_size,
            .{
                .execute = true,
                .read = true,
                .write = true,
                // .execute = prog_header.p_flags & std.elf.PF_X != 0,
                // .read = prog_header.p_flags & std.elf.PF_R != 0,
                // .write = prog_header.p_flags & std.elf.PF_W != 0,
            },
        );

        // TODO: zero out the bytes between start_page_addr and prog_header.p_vaddr

        const ph_data = data[prog_header.p_offset .. prog_header.p_offset + prog_header.p_filesz];
        const mapped_region = (@as([*]u8, @ptrFromInt(prog_header.p_vaddr)))[0..prog_header.p_memsz];
        const file_region = mapped_region[0..prog_header.p_filesz];
        const zeroed_region = mapped_region[prog_header.p_filesz..prog_header.p_memsz];

        @memcpy(file_region, ph_data);
        @memset(zeroed_region, 0);
    }

    // TODO:
    const stack_bottom = 0xA000_0000;
    const stack_size = 64 * arch.page_size;
    const stack_top = stack_bottom + stack_size;

    try new_proc.mapRegion(
        .fromInt(stack_bottom),
        stack_size,
        .{
            .execute = false,
            .read = true,
            .write = true,
        },
    );

    _ = try scheduler.newUserThread(elf_header.entry, stack_top, new_proc);

    running_processes.append(&new_proc.list_node);

    return new_proc;
}

pub fn currentProcess() *Process {
    const current_thread = scheduler.getCurrentThread();
    const gp_thread = current_thread.purpose.general;
    return gp_thread.owner_process;
}

/// Terminates current process.
pub fn killCurrentProcess(exit_code: usize) void {
    // TODO:LOCKING

    // process killing checklist:
    // - remove process from running_processes
    // - remove all threads created by the process
    // - unmap all pages from the process's address space(including its root page table)
    // - free all threads created by the process
    // - free Process structure
    // - schedule the next thread in line

    const current_process = currentProcess();

    if (@intFromEnum(current_process.id) == 0) {
        @panic("Trying to kill sentinel process");
    }

    running_processes.remove(&current_process.list_node);

    while (current_process.associated_threads.popFirst()) |thread_node| {
        const general: *Thread.General = @fieldParentPtr("process_list_node", thread_node);
        const thread: *Thread = @fieldParentPtr("purpose", @as(*Thread.Purpose, @ptrCast(general)));
        scheduler.removeThread(thread);
    }

    scheduler.scheduleCurrent();
    arch.unmapAddressSpace(current_process.root_page_table);

    std.log.debug("PID {} killed with exit code: {}", .{ @intFromEnum(current_process.id), exit_code });

    process_cache.free(current_process);
}

fn sentinel_thread() void {
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn init() *Thread {
    process_cache = slab_allocator.createObjectCache(Process);

    // TODO: maybe dont catch unreachable these errors???

    const sentinel_process_id = nextProcessId() catch unreachable;
    std.debug.assert(@intFromEnum(sentinel_process_id) == 0);

    const sentinel_process = process_cache.alloc() catch unreachable;
    sentinel_process.id = sentinel_process_id;

    running_processes.append(&sentinel_process.list_node);

    const thread = scheduler.newKernelThread(sentinel_thread, sentinel_process) catch unreachable;
    return thread;
}
