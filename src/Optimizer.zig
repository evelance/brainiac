//! # Brainfuck source optimizer
//! Find and apply various optimizations to parsed bytecode.
//! Jump offsets are not needed, i.e. Parser.finalize() does
//! not need to be called beforehand. 

const std = @import("std");
const Instruction = @import("Opcode.zig").Instruction;

pub fn optimize(allocator: std.mem.Allocator, optimization_level: u8, verbose: bool,
                program: *std.ArrayList(Instruction),
                optimized: *std.ArrayList(Instruction)) !void {
    // Copy original program without optimizations
    if (optimization_level == 0) {
        try optimized.appendSlice(program.items);
        program.clearAndFree();
        return;
    }
    
    // Apply optimization substitutions
    if (optimization_level >= 1) {
        try optimizeConstantFolding(program, optimized);
        if (verbose) {
            std.debug.print("{d:>7} instruction{s} parsed\n",
                .{ program.items.len, if (program.items.len == 1) "" else "s" });
            std.debug.print("{d:>7} after constant folding\n", .{ optimized.items.len });
        }
    }
    if (optimization_level >= 2) {
        program.clearAndFree();
        try program.appendSlice(optimized.items);
        optimized.clearAndFree();
        try optimizeLoopSet(program, optimized);
        if (verbose) {
            std.debug.print("{d:>7} after set loop optimization\n", .{ optimized.items.len });
        }
    }
    if (optimization_level >= 3) {
        program.clearAndFree();
        try program.appendSlice(optimized.items);
        optimized.clearAndFree();
        try optimizeMultiplyAccumulate(allocator, program, optimized);
        if (verbose) {
            std.debug.print("{d:>7} after multiply-accumulate optimization\n", .{ optimized.items.len });
        }
    }
    if (optimization_level >= 4) {
        const optimized2 = try optimizeMoveOffsets(allocator, optimized.items);
        defer optimized2.deinit();
        optimized.clearAndFree();
        try optimized.appendSlice(optimized2.items);
        if (verbose) {
            std.debug.print("{d:>7} after offset optimization\n", .{ optimized.items.len });
        }
    }
}

/// Merge repeated .add and .move instructions.
pub fn optimizeConstantFolding(program: *std.ArrayList(Instruction), optimized: *std.ArrayList(Instruction)) !void {
    if (program.items.len == 0)
        return;
    try optimized.append(program.items[0]);
    for (program.items[1..]) |instruction| {
        if (instruction.op == .add and optimized.getLast().op == .add) {
            optimized.items[optimized.items.len - 1].op.add += instruction.op.add;
        } else if (instruction.op == .move and optimized.getLast().op == .move) {
            optimized.items[optimized.items.len - 1].op.move += instruction.op.move;
        } else {
            try optimized.append(instruction);
        }
    }
}

/// Convert "[-]" loops into .set operations.
pub fn optimizeLoopSet(program: *std.ArrayList(Instruction), optimized: *std.ArrayList(Instruction)) !void {
    for (program.items, 0..) |instruction, addr| {
        if (instruction.op == .jump_back and addr >= 2) {
            const prev1 = program.items[addr - 1].op;
            const prev2 = program.items[addr - 2].op;
            if (prev1 == .add and prev1.add == -1 and prev2 == .jump_forward) {
                // Found "[-]"! Replace the already added "[-" with a set instruction
                _ = optimized.pop(); 
                _ = optimized.pop();
                try optimized.append(.{ .off = 0, .op = .{ .set = 0 }});
                continue;
            }
        } else if (instruction.op == .add and optimized.items.len > 0 and optimized.getLast().op == .set) {
            // .set and .add can be merged, too
            optimized.items[optimized.items.len - 1].op.set += instruction.op.add;
            continue;
        }
        try optimized.append(instruction);
    }
}

/// Convert "[>+>++<<-]" loops into one or more .mac operations
/// for cells relative to the current one followed by .set=0 for
/// the current cell.
pub fn optimizeMultiplyAccumulate(allocator: std.mem.Allocator, program: *std.ArrayList(Instruction), optimized: *std.ArrayList(Instruction)) !void {
    // Track conditions for optimization
    var loopStart: usize = 0;
    var canOptimize = false;
    var moveBalance: isize = 0;
    var startCellAdds: isize = 0;
    var macOperations = std.ArrayList(Instruction).init(allocator);
    defer macOperations.deinit();
    
    for (program.items, 0..) |instruction, addr| {
        switch (instruction.op) {
            .jump_forward => {
                // Entering loop. We will see if it can be optimized.
                loopStart = addr;
                canOptimize = true;
                moveBalance = 0;
                startCellAdds = 0;
                macOperations.clearAndFree();
            },
            .jump_back => {
                // Exiting loop. When it can be optimized, replace contained
                // instructions with .mac operations followed by .set to zero.
                if (canOptimize and moveBalance == 0 and startCellAdds == -1 and macOperations.items.len > 0) {
                    const loopContent: usize = (addr - loopStart);
                    try optimized.replaceRange(optimized.items.len - loopContent, loopContent, macOperations.items);
                    try optimized.append(.{ .off = 0, .op = .{ .set = 0 }});
                    canOptimize = false;
                    continue; // Don't add ] instruction
                }
                canOptimize = false;
            },
            .add => |value| {
                if (moveBalance == 0) {
                    startCellAdds += value;
                } else {
                    try macOperations.append(.{ .off = 0, .op =
                        .{ .mac = .{ .offset = moveBalance, .multiplier = value }}});
                }
            },
            .move => |value| {
                moveBalance += value;
            },
            // Other instructions will disable this optimization.
            else => canOptimize = false,
        }
        try optimized.append(instruction);
    }
}

/// Fold move operations into the following opcodes in the form of simple
/// offsets. E.g. ">>.>+<<<<," will be transformed into just ".+," with a
/// relative offset: .(2)+(3),(-1)
pub fn optimizeMoveOffsets(allocator: std.mem.Allocator, program: []const Instruction) !std.ArrayList(Instruction) {
    var oprog = std.ArrayList(Instruction).init(allocator);
    errdefer oprog.deinit();
    var offsets = std.ArrayList(isize).init(allocator);
    defer offsets.deinit();
    var offset: isize = 0;
    for (program) |ins| {
        switch (ins.op) {
            .jump_forward => |_| {
                try offsets.append(offset);
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .jump_forward = 0 } });
            },
            .jump_back => |_| {
                const offset_end = offset;
                offset = offsets.getLast(); _ = offsets.pop(); // Hack to make it work on Zig 0.13 and Zig 0.15
                if (offset_end != offset) {
                    try oprog.append(.{ .off = ins.off + offset_end, .op = .{ .move = offset_end - offset } });
                }
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .jump_back = 0 } });
            },
            .move => |value| {
                offset += value;
            },
            .print => |value| {
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .print = value } });
            },
            .read => |value| {
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .read = value } });
            },
            .add => |value| {
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .add = value } });
            },
            .set => |value| {
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .set = value } });
            },
            .mac => |opt| {
                try oprog.append(.{ .off = ins.off + offset, .op = .{ .mac = .{ .offset = opt.offset + offset, .multiplier = opt.multiplier } } });
            },
        }
    }
    if (offset != 0) {
        try oprog.append(.{ .off = offset, .op = .{ .move = offset } });
    }
    return oprog;
}
