//! Memory area with cells for the Brainfuck application.
//! The cell memory is enclosed by two "danger zones", i.e. protected
//! memory pages that trigger a segmentation violation on any access.
//! As the largest possible memory access offset of a Brainfuck program
//! can be determined statically, the size of the danger zone therefore
//! can be adjusted before execution and ensure a safe "sandbox" for the
//! user application.

const std = @import("std");
const builtin = @import("builtin");
const IO = @import("IO.zig");
const windows = std.os.windows;
// Hack to make it work on Zig 0.13 and Zig 0.15
const page_size = if (@hasDecl(std.heap, "page_size_min")) std.heap.page_size_min else std.mem.page_size;

/// Supported cell sizes in bit
pub const CellType = enum {
    c8,
    c16,
    c32,
    c64,
};

var map_in_use: ?[] volatile align(page_size) u8 = null;

/// Generic memory object
pub fn Memory(comptime T: anytype) type {
    return struct {
        /// Anonymous paging area allocated by the OS
        map: []align(page_size) u8,
        /// Memory cell array for the application
        cells: []T,
        /// Danger zone size in pages
        zone_pages: usize,
        /// Data pages for the cells (and potentially some padding)
        data_pages: usize,
        /// Current cell pointer
        ptr: [*]T,
        
        pub fn init(cell_count: usize, start_cell: usize) !@This() {
            // Allocate data pages and danger zone (default 1 page on each side)
            const danger_zone = 1;
            var data_pages = (cell_count * @sizeOf(T)) / page_size;
            if (@mod((cell_count * @sizeOf(T)), page_size) != 0) {
                data_pages += 1;
            }
            const allocated = try mapMemoryArea(data_pages, danger_zone);
            map_in_use = allocated.map;
            return .{
                .map = allocated.map,
                .cells = allocated.cells,
                .zone_pages = danger_zone,
                .data_pages = data_pages,
                .ptr = allocated.cells.ptr + start_cell,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            unmapMemory(self.map);
            map_in_use = null;
        }
        
        /// Ensure the danger zone is large enough to fit the given number of data elements
        pub fn updateDangerZone(self: *@This(), max_cell_offset: usize, verbose: bool) !void {
            if (verbose) {
                std.debug.print("Adjust danger zone: {d} cell{s}\n",
                    .{ max_cell_offset, if (max_cell_offset == 1) "" else "s" });
            }
            var new_zone_pages = (max_cell_offset * @sizeOf(T)) / page_size;
            if (@mod((max_cell_offset * @sizeOf(T)), page_size) != 0) {
                new_zone_pages += 1;
            }
            if (new_zone_pages <= self.zone_pages) {
                return; // Large enough already
            }
            
            // Reallocate, copy data, update pointer and unmap old area
            const allocated = try mapMemoryArea(self.data_pages, new_zone_pages);
            @memcpy(allocated.cells, self.cells);
            unmapMemory(self.map);
            self.ptr = allocated.cells.ptr + self.cellIdx(0);
            self.map = allocated.map;
            self.cells = allocated.cells;
            self.zone_pages = new_zone_pages;
            map_in_use = allocated.map;
        }
        
        /// Allocate memory pages and install a "danger zone" on both sides
        /// that will cause a SIGSEGV on both read and write accesses.
        fn mapMemoryArea(data_pages: usize, danger_pages: usize)
            !struct { map: []align(page_size) u8, cells: []T }
        {
            const total_pages = danger_pages + data_pages + danger_pages;
            const map = try mapReadWriteMemory(total_pages * page_size);
            
            // Protect the danger zones
            const left_zone_end = danger_pages * page_size;
            const left_zone = map[0..left_zone_end];
            const right_zone_start = (total_pages - danger_pages) * page_size;
            const right_zone: []align(page_size) u8 = @alignCast(map[right_zone_start..]);
            try protectMemory(left_zone, .none);
            try protectMemory(right_zone, .none);
            
            const cell_ptr: [*]T = @alignCast(@ptrCast(map.ptr + left_zone_end));
            const cell_count = (right_zone_start - left_zone_end) / @sizeOf(T);
            return .{
                .map = map,
                .cells = cell_ptr[0..cell_count],
            };
        }
        
        pub inline fn ptrAt(self: @This(), off: isize) [*]T {
            // return self.ptr + off;
            return @as([*]T, @ptrFromInt(@as(usize, @intFromPtr(self.ptr)) +% @as(usize, @bitCast(off)) *% @sizeOf(T)));
        }
        
        /// Called by interpreter
        pub inline fn move(self: *@This(), off: isize) void {
            // self.ptr += off;
            self.ptr = self.ptrAt(off);
        }
        pub inline fn load(self: @This(), off: isize) T {
            // return self.ptr[off];
            return self.ptrAt(off)[0];
        }
        pub inline fn store(self: *@This(), off: isize, c: T) void {
            // self.ptr[off] = c;
            self.ptrAt(off)[0] = c;
        }
        
        pub fn cellIdx(self: *@This(), off: isize) usize {
            const base_addr: usize = @intFromPtr(self.cells.ptr);
            const current_addr: usize = @intFromPtr(self.ptr);
            return (current_addr - base_addr) / @sizeOf(T) +% @as(usize, @bitCast(off));
        }
        
        /// Get real pointer to current memory cell
        pub fn getPointer(self: *@This()) [*]T {
            return self.ptr;
        }
        
        /// Set current cell index from real pointer
        pub fn setPointer(self: *@This(), pointer: [*]T) void {
            std.debug.assert(@mod(@intFromPtr(self.ptr), @sizeOf(T)) == 0); // Somehow alignment got broken
            self.ptr = pointer;
        }
        
        /// Check if current cell pointer is still in allowed area
        pub fn checkPointer(self: *@This()) bool {
            const base_addr: usize = @intFromPtr(self.cells.ptr);
            const end_addr: usize = @intFromPtr(self.cells.ptr + self.cells.len);
            const current_addr: usize = @intFromPtr(self.ptr);
            return current_addr >= base_addr and current_addr < end_addr;
        }
    };
}

/// Allocate anonymous memory mapping (POSIX and Windows)
pub fn mapReadWriteMemory(min_size: usize) ![]align(page_size) u8 {
    // Round up to entire pages
    var num_pages = min_size / page_size;
    if (@mod(min_size, page_size) != 0) {
        num_pages += 1;
    }
    const map_size = num_pages * page_size;
    
    // Request new memory
    if (comptime builtin.os.tag == .windows) {
        const memory = try windows.VirtualAlloc(
            null,
            map_size,
            windows.MEM_COMMIT | windows.MEM_RESERVE,
            windows.PAGE_READWRITE
        );
        const memory_ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(memory));
        return memory_ptr[0..map_size];
    } else {
        return std.posix.mmap(
            null,
            map_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1, 0
        );
    }
}

/// Change page protection flags (POSIX and Windows)
pub fn protectMemory(memory: []align(page_size) u8, protection: enum { none, exec }) !void {
    if (comptime builtin.os.tag == .windows) {
        var old_protect: windows.DWORD = undefined;
        try windows.VirtualProtect(memory.ptr, memory.len, switch (protection) {
            .none => windows.PAGE_NOACCESS,
            .exec => windows.PAGE_EXECUTE_READ,
        }, &old_protect);
    } else {
        try std.posix.mprotect(memory, switch (protection) {
            .none => std.posix.PROT.NONE,
            .exec => std.posix.PROT.EXEC | std.posix.PROT.READ,
        });
    }
}

/// Free allocated memory area (POSIX and Windows)
pub fn unmapMemory(map: []align(page_size) u8) void {
    if (comptime builtin.os.tag == .windows) {
        windows.VirtualFree(map.ptr, 0, windows.MEM_RELEASE);
    } else {
        std.posix.munmap(map);
    }
}

/// Custom segfault handling for the currently active memory area
pub fn enableCustomSEGVHandler() !void {
    if (comptime builtin.os.tag == .windows) {
        // Windows Structured Exception Handling
        _ = windows.kernel32.AddVectoredExceptionHandler(1, &onWindowsException);
    } else {
        // POSIX signal handler
        try std.posix.sigaction(std.posix.SIG.SEGV, &.{
            .handler = .{ .sigaction = onSEGV },
            .mask = std.posix.empty_sigset,
            .flags = std.posix.SA.SIGINFO,
        }, null);
    }
}

/// POSIX SEGV signal handler
fn onSEGV(_: i32, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.C) void {
    // Restore default handler for "regular" segfaults.
    std.posix.sigaction(std.posix.SIG.SEGV, &.{
        .handler = .{ .sigaction = null },
        .mask = std.posix.empty_sigset,
        .flags = std.posix.SA.RESETHAND,
    }, null) catch {};
    _ = checkUserCrash(@intFromPtr(info.fields.sigfault.addr));
}

/// Windows vectored exception handler
fn onWindowsException(info: *windows.EXCEPTION_POINTERS) callconv(.C) c_long {
    // Check if it's an access violation (equivalent to SIGSEGV)
    if (info.ExceptionRecord.ExceptionCode == windows.EXCEPTION_ACCESS_VIOLATION) {
        checkUserCrash(info.ExceptionRecord.ExceptionInformation[1]);
    }
    
    // Not user memory, continue normal exception handling
    return windows.EXCEPTION_CONTINUE_SEARCH;
}

/// Exit with a nice message instead of a crash if the SEGV was
/// caused by the user application going into the danger zone.
fn checkUserCrash(segv_addr: usize) void {
    if (map_in_use) |map| {
        const map_start: usize = @intFromPtr(map.ptr);
        const map_end: usize = @intFromPtr(map.ptr + map.len);
        if (segv_addr >= map_start and segv_addr < map_end) {
            IO.printWarning("Reached end of tape. Here be dragons!");
            std.process.exit(1);
        }
    }
}
