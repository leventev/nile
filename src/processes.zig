const std = @import("std");
const slab_allocator = @import("mem/slab_allocator.zig");
const scheduler = @import("scheduler.zig");
const Process = @import("Process.zig");
const Thread = @import("Thread.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const vfs = @import("vfs.zig");
const SyscallError = @import("syscall/errors.zig").SyscallError;
const buddy_allocator = @import("mem/buddy_allocator.zig");

const log = std.log.scoped(.processes);

var running_processes: ?*Process = null;
var processes_available: std.bit_set.ArrayBitSet(usize, Process.Id.max) = .initFull();

var process_cache: slab_allocator.ObjectCache(Process) = .{};

pub const Error = error{no_available_threads};

fn nextProcessId() Error!Process.Id {
    const process_id_int = processes_available.toggleFirstSet() orelse
        return error.no_available_threads;
    return @enumFromInt(process_id_int);
}

pub fn spawnProcess(
    file: vfs.OpenFile,
    parent_pid: ?Process.Id,
    parent_mount_table: *vfs.MountTable,
    parent_root_page_table: arch.PageTable,
) SyscallError!*Process {
    const new_proc_id = nextProcessId() catch return SyscallError.TooManyProcesses;
    var new_proc = process_cache.alloc() catch return SyscallError.OutOfMemory;

    new_proc.id = new_proc_id;
    new_proc.parent_id = parent_pid;
    new_proc.mount_table = parent_mount_table;
    new_proc.root_page_table = try mm.clonePageTable(parent_root_page_table, true);

    // TODO: USE PAGE CACHE
    const file_size = file.dir_ent.data.regular.size;
    const order = buddy_allocator.blockOrderFromSize(file_size);
    const file_data_phys = buddy_allocator.allocBlock(order) catch unreachable;
    defer buddy_allocator.deallocBlock(file_data_phys, order);

    const file_data = mm.physicalToVirtualAddress(file_data_phys).asPtr([*]u8)[0..file_size];
    _ = file.read(file_data, 0) catch @panic("TODO: READ FAILED");

    var reader = std.Io.Reader.fixed(file_data);
    const elf_header = std.elf.Header.read(&reader) catch @panic("TODO: elf header error");

    // TODO: do validation
    var prog_header_it = elf_header.iterateProgramHeadersBuffer(file_data);
    while (prog_header_it.next() catch unreachable) |prog_header| {
        if (prog_header.p_type != std.elf.PT_LOAD)
            continue;

        if (prog_header.p_memsz == 0) continue;

        // TODO: error
        std.debug.assert(
            prog_header.p_vaddr % prog_header.p_align == prog_header.p_offset % prog_header.p_align,
        );

        // TODO: handle case when filesz > memsz
        new_proc.mapRegion(
            mm.UserAddress.fromInt(prog_header.p_vaddr) orelse return error.InvalidELF,
            prog_header.p_memsz,
            .{
                .file = file,
                .offset = prog_header.p_offset,
            },
            .{
                .execute = prog_header.p_flags & std.elf.PF_X != 0,
                .read = prog_header.p_flags & std.elf.PF_R != 0,
                .write = prog_header.p_flags & std.elf.PF_W != 0,
            },
        ) catch |err| return switch (err) {
            error.InvalidSize, error.InsideKernelSpace, error.Overlap => error.InvalidELF,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // TODO:
    const stack_top = 0xA000_0000;
    const stack_size = 64 * arch.page_size;
    const stack_bottom = stack_top + stack_size;

    new_proc.mapRegion(
        mm.UserAddress.fromInt(stack_top) orelse unreachable,
        stack_size,
        null,
        .{
            .execute = false,
            .read = true,
            .write = true,
        },
    ) catch return error.OutOfMemory;

    var next_ptr = &running_processes;
    while (next_ptr.*) |added_process| : (next_ptr = &added_process.next) {}
    next_ptr.* = new_proc;

    _ = scheduler.newUserThread(elf_header.entry, stack_bottom, new_proc) catch return error.OutOfMemory;

    return new_proc;
}

pub fn currentProcess() *Process {
    const current_thread = scheduler.getCurrentThread();
    const gp_thread = current_thread.purpose.general;
    return gp_thread.owner_process;
}

/// Terminates current process.
pub fn killCurrentProcess(exit_code: isize) void {
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

    {
        var next_ptr = &running_processes;
        while (next_ptr.*) |added_process| : (next_ptr = &added_process.next) {
            if (added_process != current_process) continue;
            next_ptr.* = current_process.next;
            break;
        }
    }
    {
        var next_ptr = &current_process.associated_threads;
        while (next_ptr.*) |thread| : (next_ptr = &thread.purpose.general.process_list_next) {
            scheduler.removeThread(thread);
        }
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

var empty_mount_table: vfs.MountTable = .{
    .lock = .{ .locked = 0 },
    .mount_count = 0,
    .mounts = null,
};

pub fn init(root_page_table: mm.PageTable) *Thread {
    process_cache = slab_allocator.createObjectCache(Process);
    Process.MappedRegion.cache = slab_allocator.createObjectCache(Process.MappedRegion);

    // TODO: maybe dont catch unreachable these errors???

    const sentinel_process_id = nextProcessId() catch unreachable;
    std.debug.assert(@intFromEnum(sentinel_process_id) == 0);

    const sentinel_process = process_cache.alloc() catch unreachable;
    sentinel_process.id = sentinel_process_id;
    sentinel_process.mount_table = &empty_mount_table;
    // TODO: we copy it because in switchAddressSpace we try to convert its virt address
    // to physical with HHDM but the original root page table is in .bss which cant be converted
    sentinel_process.root_page_table = mm.clonePageTable(root_page_table, true) catch unreachable;

    var next_ptr = &running_processes;
    while (next_ptr.*) |added_process| : (next_ptr = &added_process.next) {}
    next_ptr.* = sentinel_process;

    const thread = scheduler.newKernelThread(sentinel_thread, sentinel_process) catch unreachable;
    return thread;
}
