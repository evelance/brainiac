const std = @import("std");

DEFINITIONS

inline fn read() CellType {
    return std.io.getStdIn().reader().readByte() catch { return 0; };
}

inline fn print(c: CellType) void {
    std.io.getStdOut().writer().writeByte(@truncate(c)) catch {};
}

/// ptr + off;
inline fn ptrAt(ptr: [*]CellType, off: isize) [*]CellType {
    return @as([*]CellType, @ptrFromInt(@as(usize, @intFromPtr(ptr)) +% @as(usize, @bitCast(off)) *% @sizeOf(CellType)));
}

pub fn main() !void {
    @setEvalBranchQuota(1000000);
    var mem = [_]CellType{0} ** MEMSIZE;
    var ptr = mem[INITIAL_CELL..].ptr;
    PROGRAM
}
