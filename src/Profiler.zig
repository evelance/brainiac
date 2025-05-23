//! Profile Brainfuck program during interpretation.
//! Counts instruction execution and memory cell uses.
//! After completion, generates an HTML report.

const std = @import("std");
const Instruction = @import("Opcode.zig").Instruction;

pub const Profile = struct {
    program: []Instruction,
    profile: []usize,   // Instruction execution counters
};

allocator: std.mem.Allocator,
/// Brainfuck program being interpreted
program: []Instruction,
/// Per-instruction execution counters
profile: []usize,
/// Total number of executed instructions
execution_count: usize,
/// Initial cell address
start_cell: usize,
/// Highest used cell address
max_cell: usize,
/// Lowest used cell address
min_cell: usize,
/// Highest recorded cell value
max_value: i64,
/// Lowest recorded cell value
min_value: i64,

pub fn init(allocator: std.mem.Allocator, program: []Instruction) !@This() {
    const profile = try allocator.alloc(usize, program.len);
    for (profile) |*field| {
        field.* = 0;
    }
    return .{
        .allocator = allocator,
        .program = program,
        .profile = profile,
        .execution_count = 0,
        .start_cell = 0,
        .max_cell = 0,
        .min_cell = 0,
        .max_value = 0,
        .min_value = 0,
    };
}

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.profile);
}

/// Store start cell value
pub fn start(self: *@This(), pos: usize) void {
    self.start_cell = pos;
    self.min_cell = pos;
    self.max_cell = pos;
}

/// Record execution of an instruction.
pub fn recordExecute(self: *@This(), pos: usize) void {
    self.profile[pos] += 1;
    self.execution_count += 1;
}

/// Record memory cell use.
pub fn recordMemUse(self: *@This(), cell: usize, value: i64) void {
    self.max_cell = @max(self.max_cell, cell);
    self.min_cell = @min(self.min_cell, cell);
    self.max_value = @max(self.max_value, value);
    self.min_value = @min(self.min_value, value);
}

/// Write JSON data for the JavaScript profiler.
pub fn writeJSON(self: *@This(), source_file: ?[]const u8, outstream: anytype) !void {
    var writer = std.json.writeStream(outstream, .{});
    try writer.beginObject();
    try writer.objectField("source_file");
    try writer.write(source_file orelse "<stdin>");
    
    // Instructions
    try writer.objectField("program");
    try writer.beginArray();
    for (self.program) |ins| {
        try writer.beginArray();
        try writer.write(@intFromEnum(ins.op));
        try writer.write(ins.off);
        switch (ins.op) {
            .add => |inc| try writer.write(inc),
            .move => |inc| try writer.write(inc),
            .jump_forward => |addr| try writer.write(addr),
            .jump_back => |addr| try writer.write(addr),
            .set => |val| try writer.write(val),
            .mac => |op| {
                try writer.write(op.offset);
                try writer.write(op.multiplier);
            },
            else => {}
        }
        try writer.endArray();
    }
    try writer.endArray();
    
    // Execution count for every instruction
    try writer.objectField("profile");
    try writer.beginArray();
    for (self.profile) |count| {
        try writer.write(count);
    }
    try writer.endArray();
    try writer.endObject();
}

pub fn report(self: *@This(), output_path: []const u8, source_file: ?[]const u8) !void {
    std.debug.print("Profiler results:\n", .{});
    std.debug.print("  Executed instructions: {d}\n", .{ self.execution_count });
    std.debug.print("  Cell usage: {d} ({d}..{d})\n",
        .{ self.max_cell - self.min_cell + 1,
           @as(i64,@intCast(self.min_cell)) - @as(i64,@intCast(self.start_cell)),
           @as(i64,@intCast(self.max_cell)) - @as(i64,@intCast(self.start_cell)) });
    std.debug.print("  Value range: {d}..{d}\n",
        .{ self.min_value, self.max_value });
    
    std.debug.print("Execution profile written to '{s}'\n", .{ output_path });
    
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    
    var sequence = std.mem.splitSequence(u8, @embedFile("templates/profiler.tpl.htm"), "PROFILER_DATA");
    try file.writeAll(sequence.first());
    while (sequence.next()) |chunk| {
        try self.writeJSON(source_file, file.writer());
        try file.writeAll(chunk);
    }
}
