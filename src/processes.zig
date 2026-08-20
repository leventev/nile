const std = @import("std");
const core = @import("core");
const MessageType = core.message.MessageType;
const SyscallError = core.SyscallError;
const slab_allocator = @import("mem/slab_allocator.zig");
const scheduler = @import("scheduler.zig");
const Process = @import("Process.zig");
const Thread = @import("Thread.zig");
const arch = @import("arch/arch.zig");
const mm = @import("mem/mm.zig");
const vfs = @import("vfs.zig");
const buddy_allocator = @import("mem/buddy_allocator.zig");
const ProcessFilesystem = @import("ProcessFilesystem.zig");

const log = std.log.scoped(.processes);

var running_processes: ?*Process = null;
var processes_available: std.bit_set.ArrayBitSet(usize, Process.Id.max) = .initFull();
pub var process_count: usize = 0;

var process_cache: slab_allocator.ObjectCache(Process) = .{};

fn nextProcessId() error{TooManyProcesses}!Process.Id {
    const process_id_int = processes_available.toggleFirstSet() orelse
        return error.TooManyProcesses;
    return @enumFromInt(process_id_int);
}

pub fn spawnProcess(
    file: vfs.OpenFile,
    parent: ?*Process,
    mount_table: *vfs.MountTable,
    root_page_table: arch.PageTable,
    procfs: *ProcessFilesystem,
) !*Process {
    var new_proc = try newProcess();

    new_proc.parent = parent;
    new_proc.mount_table = mount_table;
    new_proc.root_page_table = try mm.clonePageTable(root_page_table, true);
    new_proc.procfs = procfs;

    // TODO: do something about the assumption that file is a Regular
    // TODO: USE PAGE CACHE
    const regular = file.dir_ent.regular();
    const file_size = regular.size;
    const order = buddy_allocator.blockOrderFromSize(file_size);
    const file_data_frame_desc = buddy_allocator.allocBlock(order) catch unreachable;
    const file_data_phys = file_data_frame_desc.physical();
    defer buddy_allocator.deallocBlock(file_data_frame_desc);

    const file_data = mm.physicalToVirtual(file_data_phys).asPtr([*]u8)[0..file_size];
    var dummy_offset: usize = 0;
    const bytes_read = file.read(file_data, &dummy_offset) catch @panic("TODO: READ FAILED");
    std.debug.assert(bytes_read == file_size);

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

        // TODO: handle case when filesz < memsz
        new_proc.mapRegion(
            prog_header.p_vaddr / arch.page_size,
            prog_header.p_memsz / arch.page_size,
            .{
                .source = .{
                    .file = .{
                        .open_file = file,
                        .page_offset = prog_header.p_offset / arch.page_size,
                    },
                },
                .page_offset = 0,
                // TODO: +1 is prolly wrong
                .page_count = prog_header.p_filesz / arch.page_size + 1,
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

    // argument
    const arg_str = "hello world!";
    const arg_arr_size = MessageType.uint8.arrayRequiredSizeBackwards(arg_str.len, stack_top);
    const buf_phys = buddy_allocator.allocBlock(0) catch unreachable;
    const buf = mm.physicalToVirtual(buf_phys.physical()).asPtr([*]u8)[0..arch.page_size];

    const subbuf = buf[arch.page_size - arg_arr_size .. arch.page_size];

    const arg_message = MessageType.uint8.writeArray(arg_str, subbuf) orelse unreachable;

    new_proc.mapRegion(
        stack_top / arch.page_size,
        stack_size / arch.page_size,
        .{
            .source = .{ .memory = buf.ptr },
            .page_offset = (stack_size - arch.page_size) / arch.page_size,
            // TODO:
            .page_count = 1,
        },
        .{
            .execute = false,
            .read = true,
            .write = true,
        },
    ) catch return error.OutOfMemory;

    var next_ptr = &running_processes;
    while (next_ptr.*) |added_process| : (next_ptr = &added_process.next) {}
    next_ptr.* = new_proc;

    const main_thread = scheduler.newUserThread(elf_header.entry, stack_bottom, new_proc) catch
        return error.OutOfMemory;

    main_thread.purpose.general.user.?.state.gprs[10] = stack_bottom - arg_message.len;
    main_thread.purpose.general.user.?.state.gprs[11] = arg_message.len;
    // TODO: BIG TODO
    main_thread.purpose.general.user.?.state.gprs[2] = std.mem.alignBackward(
        usize,
        main_thread.purpose.general.user.?.state.gprs[2] - arg_message.len,
        16,
    );

    dumpProcesses();

    process_count += 1;

    procfs.addProcess(new_proc) catch unreachable;

    return new_proc;
}

pub fn currentProcess() *Process {
    const current_thread = scheduler.getCurrentThread();
    const gp_thread = current_thread.purpose.general;
    return gp_thread.owner_process;
}

pub fn dumpProcesses() void {
    std.log.debug("Running processes:", .{});
    var proc_ptr = running_processes;
    while (proc_ptr) |process| : (proc_ptr = process.next) {
        std.log.debug("  PID {} page table phys: 0x{x}", .{
            @intFromEnum(process.id),
            mm.virtualToPhysical(
                .fromInt(@intFromPtr(process.root_page_table.entries)),
            ).int,
        });
        var thread_ptr = process.associated_threads;
        while (thread_ptr) |thread| : (thread_ptr = thread.purpose.general.process_list_next) {
            std.log.debug("    TID {}", .{@intFromEnum(thread.id)});
        }
    }
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
    // TODO: TEST WHETHER THE ADDRESS SPACE IS CORRECTLY UNMAPPED

    std.log.debug("PID {} killed with exit code: {}", .{ @intFromEnum(current_process.id), exit_code });

    process_cache.free(current_process);

    if (current_process.parent) |parent| {
        parent.last_child_exit_code = exit_code;
        parent.last_child_exit_code_semaphore.add();
    }

    process_count -= 1;
    processes_available.set(@intFromEnum(current_process.id));

    // TODO: schedule next thread??
}

fn sentinel_thread() void {
    while (true) {
        asm volatile ("wfi");
    }
}

var empty_mount_table: vfs.MountTable = .{
    .mount_count = 0,
    .mounts = null,
    .spinlock = .unlocked,
};

fn newProcess() !*Process {
    const process_id = try nextProcessId();
    const process = try process_cache.alloc();
    process.* = .{
        .id = process_id,
        .last_child_exit_code = null,
        .last_child_exit_code_semaphore = .default,
        .next = null,
        .associated_threads = null,
        .mapped_region_count = 0,
        .mapped_regions = null,
        .parent = null,

        .procfs = undefined,
        .root_page_table = undefined,
        // TODO: temporary
        .file_descriptor_table = @splat(null),
        .mount_table = undefined,
    };

    // the rest of the fields are set by the caller

    return process;
}

pub fn init(root_page_table: mm.PageTable, procfs: *ProcessFilesystem) *Thread {
    process_cache = slab_allocator.createObjectCache(Process);
    Process.MappedRegion.cache = slab_allocator.createObjectCache(Process.MappedRegion);

    const sentinel_process = newProcess() catch unreachable;
    std.debug.assert(@intFromEnum(sentinel_process.id) == 0);
    sentinel_process.mount_table = &empty_mount_table;
    sentinel_process.procfs = procfs;

    // TODO: we copy it because in switchAddressSpace we try to convert its virt address
    // to physical with HHDM but the original root page table is in .bss which cant be converted
    sentinel_process.root_page_table = mm.clonePageTable(root_page_table, true) catch unreachable;

    var next_ptr = &running_processes;
    while (next_ptr.*) |added_process| : (next_ptr = &added_process.next) {}
    next_ptr.* = sentinel_process;

    const thread = scheduler.newKernelThread(sentinel_thread, sentinel_process) catch unreachable;

    process_count += 1;

    return thread;
}
