//! # Brainfuck to C transpiler
//! Higher Brainfuck source optimization levels can result in
//! better performance of the compiled C code, too!

const std = @import("std");
const Instruction = @import("Opcode.zig").Instruction;
const CellType = @import("Memory.zig").CellType;

/// Output C code
pub fn writeC(cell_type: CellType, memsize: usize, initial_cell: usize, ops: []const Instruction, writer: anytype) !void {
    // Template must meet following conditions:
    // - tabs as indents
    // - definitions_str and program_str appear each exactly once and in this order
    // - program is indented by 1
    const template = @embedFile("transpiler.tpl.c");
    const indent_str = "\t";
    const definitions_str = "DEFINITIONS\n";
    const program_str = indent_str ++ "PROGRAM\n";
    
    // DEFINITIONS
    var seq_cell_type = std.mem.splitSequence(u8, template, definitions_str);
    try writer.writeAll(seq_cell_type.first());
    try std.fmt.format(writer, "typedef {s} cell_t;\n", .{
        switch (cell_type) {
            .c8 => "uint8_t",
            .c16 => "uint16_t",
            .c32 => "uint32_t",
            .c64 => "uint64_t",
        }
    });
    try std.fmt.format(writer, "#define MEMSIZE {d}\n", .{ memsize });
    try std.fmt.format(writer, "#define INITIAL_CELL {d}\n", .{ initial_cell });
    
    // PROGRAM
    var seq_program = std.mem.splitSequence(u8, seq_cell_type.next().?, program_str);
    try writer.writeAll(seq_program.first());
    var indent: usize = 1;
    for (ops, 0..) |ins, i| {
        switch (ins.op) {
            .add => |value| {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "c[{d}] += {d}; // #{d}\n", .{ ins.off, value, i });
            },
            .set => |value| {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "c[{d}] = {d}; // #{d}\n", .{ ins.off, value, i });
            },
            .move => |value| {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "c += {d}; // #{d}\n", .{ value, i });
            },
            .mac => |opt| {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "c[{d}] += c[{d}] * {d}; // #{d}\n", .{ opt.offset, ins.off, opt.multiplier, i });
            },
            .print => {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "print(c[{d}]); // #{d}\n", .{ ins.off, i });
            },
            .read => {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "read(&c[{d}]); // #{d}\n", .{ ins.off, i });
            },
            .jump_forward => {
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "while (c[{d}]) {{ // #{d}\n", .{ ins.off, i });
                indent += 1;
            },
            .jump_back => {
                indent -= 1;
                try writer.writeBytesNTimes(indent_str, indent);
                try std.fmt.format(writer, "}} // #{d}\n", .{ i });
            },
        }
    }
    
    try writer.writeAll(seq_program.next().?);
}
