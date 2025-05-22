//! Compile (optimized) Brainfuck opcodes into RV64IM machine code.
//! Requires I extension for -O0, -O1, -O2 and M extension for -O3.
//! Generates a function adhering to the GNU calling convention.

const std = @import("std");
const rv64 = @import("RV64.zig");
const RV_X = rv64.RV_X;
const Instruction = @import("Opcode.zig").Instruction;
const CellType = @import("Memory.zig").CellType;

fn fitsInt(value: anytype, comptime T: type) bool {
    return value >= std.math.minInt(T) and value <= std.math.maxInt(T);
}

/// Simple RISC-V instruction assembler.
/// Uses compressed instructions when possible.
const Assembler = struct {
    const Block = struct {
        /// Generated machine code
        text: std.ArrayList(u8),
        /// Blocks can be basic blocks (linear sequence of unconditional
        /// instructions) or branches / jumps to a label (block index).
        type: union(enum) {
            basic,
            jump: struct { target: usize, },
            bne: struct { rs1: RV_X, rs2: RV_X, target: usize, },
            beq: struct { rs1: RV_X, rs2: RV_X, target: usize, },
        },
    };
    
    allocator: std.mem.Allocator,
    /// Already generated blocks
    blocks: std.ArrayList(Block),
    /// Pointer to instruction sequence
    text: *std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        var blocks = std.ArrayList(Block).init(allocator);
        try blocks.append(.{ .text = std.ArrayList(u8).init(allocator), .type = .basic });
        return .{
            .allocator = allocator,
            .blocks = blocks,
            .text = &blocks.items[0].text,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        for (self.blocks.items) |block| {
            block.text.deinit();
        }
        self.blocks.deinit();
    }
    
    pub fn assemble(self: *@This()) ![]u8 {
        // Calculate byte offset of each block in the final
        // executable. Branches are left empty at first.
        var block_addr = std.ArrayList(isize).init(self.allocator);
        defer block_addr.deinit();
        
        var address: isize = 0;
        for (self.blocks.items) |block| {
            try block_addr.append(address);
            address += @intCast(block.text.items.len);
        }
        
        // Generate code for jumps and branches as we now aproximately know
        // the actual jump target address for each label. Inserting the new
        // code invalidates existing jump targets, unfortunately, and updating
        // the jump distance may lead to larger code again. Loop until no new
        // code has to be inserted.
        var branch_expanded = true;
        while (branch_expanded) {
            branch_expanded = false;
            for (self.blocks.items, 0..) |*block, i| {
                const old_len = block.text.items.len;
                switch (block.type) {
                    .jump => |branch| {
                        block.text.clearAndFree();
                        const offset = block_addr.items[branch.target] - block_addr.items[i];
                        if (fitsInt(offset, i12)) {
                            try rv64.c_j(&block.text, @intCast(offset));
                        } else {
                            try rv64.jal(&block.text, .zero, @intCast(offset));
                        }
                    },
                    .bne => |branch| {
                        block.text.clearAndFree();
                        const offset = block_addr.items[branch.target] - block_addr.items[i];
                        if (branch.rs2 == .zero and rv64.is3BitReg(branch.rs1) and fitsInt(offset, i9)) {
                            try rv64.c_bnez(&block.text, branch.rs1, @intCast(offset));
                        } else if (fitsInt(offset, i13)) {
                            try rv64.bne(&block.text, branch.rs1, branch.rs2, @intCast(offset));
                        } else {
                            // Invert branch condition and jump over call instead
                            const call_size = 8;
                            var branch_size: isize = 0;
                            if (branch.rs2 == .zero and rv64.is3BitReg(branch.rs1)) {
                                branch_size = 2;
                                try rv64.c_beqz(&block.text, branch.rs1, @intCast(branch_size + call_size));
                            } else {
                                branch_size = 4;
                                try rv64.beq(&block.text, branch.rs1, branch.rs2, @intCast(branch_size + call_size));
                            }
                            const call_offset: isize = offset - branch_size;
                            try rv64.call(&block.text, @intCast(call_offset));
                        }
                    },
                    .beq => |branch| {
                        block.text.clearAndFree();
                        const offset = block_addr.items[branch.target] - block_addr.items[i];
                        if (branch.rs2 == .zero and rv64.is3BitReg(branch.rs1) and fitsInt(offset, i9)) {
                            try rv64.c_beqz(&block.text, branch.rs1, @intCast(offset));
                        } else if (fitsInt(offset, i13)) {
                            try rv64.beq(&block.text, branch.rs1, branch.rs2, @intCast(offset));
                        } else {
                            // Invert branch condition and jump over call instead
                            const call_size = 8;
                            var branch_size: isize = 0;
                            if (branch.rs2 == .zero and rv64.is3BitReg(branch.rs1)) {
                                branch_size = 2;
                                try rv64.c_bnez(&block.text, branch.rs1, @intCast(branch_size + call_size));
                            } else {
                                branch_size = 4;
                                try rv64.bne(&block.text, branch.rs1, branch.rs2, @intCast(branch_size + call_size));
                            }
                            const call_offset: isize = offset - branch_size;
                            try rv64.call(&block.text, @intCast(call_offset));
                        }
                    },
                    else => {},
                }
                if (block.text.items.len > old_len) {
                    branch_expanded = true;
                }
                
                // We cannot allow the code to shrink as it could lead to an
                // infininite loop. This case is probably very rare, though.
                while (block.text.items.len < old_len) {
                    const fill: usize = old_len - block.text.items.len;
                    std.debug.print("WARNING: Jump code has shrunken! Filling with {d} bytes of NOPs\n", .{ fill });
                    std.debug.assert(@mod(fill, 2) == 0);
                    if (fill >= 4) {
                        try rv64.nop(&block.text);
                    } else {
                        try rv64.c_nop(&block.text);
                    }
                }
            }
            
            // Update addresses for next round
            address = 0;
            if (branch_expanded) {
                address = 0;
                for (self.blocks.items, 0..) |block, i| {
                    block_addr.items[i] = address;
                    address += @intCast(block.text.items.len);
                }
            }
        }
        
        // Concatenate all blocks into the final executable.
        var executable = std.ArrayList(u8).init(self.allocator);
        defer executable.deinit();
        for (self.blocks.items) |block| {
            try executable.appendSlice(block.text.items);
        }
        return executable.toOwnedSlice();
    }
    
    /// Get label for current block (jump target) 
    pub fn getLabel(self: *@This()) usize {
        return self.blocks.items.len - 1;
    }
    
    /// Start new basic block and return its label.
    pub fn makeLabel(self: *@This()) !usize {
        try self.blocks.append(.{ .text = std.ArrayList(u8).init(self.allocator), .type = .basic });
        self.text = &self.blocks.items[self.blocks.items.len - 1].text;
        return self.getLabel();
    }
    
    /// Set target label of jump or branch.
    pub fn setTarget(self: *@This(), branch_label: usize, target_label: usize) void {
        switch (self.blocks.items[branch_label].type) {
            .basic => {}, // Not a branch
            .jump => |*branch| branch.target = target_label,
            .bne => |*branch| branch.target = target_label,
            .beq => |*branch| branch.target = target_label,
        }
    }
    
    /// Jump to label. Returns label of the jump itself.
    pub fn j(self: *@This(), label: usize) !usize {
        try self.blocks.append(.{
            .text = std.ArrayList(u8).init(self.allocator),
            .type = .{ .jump = .{ .target = label } },
        });
        return try self.makeLabel() - 1;
    }
    
    /// Branch If Not Equal (to label). Returns label of the branch itself.
    pub fn bne(self: *@This(), rs1: RV_X, rs2: RV_X, label: usize) !usize {
        try self.blocks.append(.{
            .text = std.ArrayList(u8).init(self.allocator),
            .type = .{ .bne = .{ .rs1 = rs1, .rs2 = rs2, .target = label } },
        });
        return try self.makeLabel() - 1;
    }
    
    /// Branch If Not Equal to Zero (to label). Returns label of the branch itself.
    pub fn bnez(self: *@This(), rs1: RV_X, label: usize) !usize {
        return self.bne(rs1, .zero, label);
    }
    
    /// Branch If Equal (to label). Returns label of the branch itself.
    pub fn beq(self: *@This(), rs1: RV_X, rs2: RV_X, label: usize) !usize {
        try self.blocks.append(.{
            .text = std.ArrayList(u8).init(self.allocator),
            .type = .{ .beq = .{ .rs1 = rs1, .rs2 = rs2, .target = label } },
        });
        return try self.makeLabel() - 1;
    }
    
    /// Branch If Equal to Zero (to label). Returns label of the branch itself.
    pub fn beqz(self: *@This(), rs1: RV_X, label: usize) !usize {
        return self.beq(rs1, .zero, label);
    }
    
    /// Load cell depending on the cell type: l[d|w|h|b] rd, offset(rs1)
    pub fn loadCell(self: *@This(), cell_type: CellType, rd: RV_X, rs1: RV_X, offset: i12) !void {
        return switch (cell_type) {
            .c8 => self.lb(rd, rs1, offset),
            .c16 => self.lh(rd, rs1, offset),
            .c32 => self.lw(rd, rs1, offset),
            .c64 => self.ld(rd, rs1, offset),
        };
    }
    
    /// Store cell depending on the cell type: s[d|w|h|b] rs2, offset(rs1)
    pub fn storeCell(self: *@This(), cell_type: CellType, rs1: RV_X, rs2: RV_X, offset: i12) !void {
        return switch (cell_type) {
            .c8 => self.sb(rs1, rs2, offset),
            .c16 => self.sh(rs1, rs2, offset),
            .c32 => self.sw(rs1, rs2, offset),
            .c64 => self.sd(rs1, rs2, offset),
        };
    }
    
    /// Push registers on the stack
    pub fn push(self: *@This(), registers: []const RV_X) !void {
        const ilen: isize = @intCast(registers.len);
        try self.addi(.sp, .sp, @intCast(-(ilen * rv64.XSZ)));
        for (registers, 1..) |reg, i| {
            try self.sd(.sp, reg, @intCast((registers.len - i) * rv64.XSZ));
        }
    }
    
    /// Pop registers off the stack
    pub fn pop(self: *@This(), registers: []const RV_X) !void {
        for (registers, 1..) |reg, i| {
            try self.ld(reg, .sp, @intCast((registers.len - i) * rv64.XSZ));
        }
        try self.addi(.sp, .sp, @intCast(registers.len * rv64.XSZ));
    }
    
    /// Add: add rd, rs1, rs2
    pub fn add(self: *@This(), rd: RV_X, rs1: RV_X, rs2: RV_X) !void {
        if (rd == rs1 and rd != .zero and rs2 != .zero) {
            try rv64.c_add(self.text, rd, rs2);
        } else {
            try rv64.add(self.text, rd, rs1, rs2);
        }
    }
    
    /// Add Immediate: addi rd, rs1, immediate
    pub fn addi(self: *@This(), rd: RV_X, rs1: RV_X, immediate: i12) !void {
        if (rd == rs1 and immediate != 0 and fitsInt(immediate, i6)) {
            try rv64.c_addi(self.text, rd, @intCast(immediate));
        } else {
            try rv64.addi(self.text, rd, rs1, immediate);
        }
    }
    
    /// Jump And Link Register: jalr rd, offset(rs1)
    pub fn jalr(self: *@This(), rd: RV_X, rs1: RV_X, offset: i12) !void {
        if (rd == .ra and offset == 0) {
            try rv64.c_jalr(self.text, rs1);
        } else {
            try rv64.jalr(self.text, rd, rs1, offset);
        }
    }
    
    /// Load Immediate
    pub fn li(self: *@This(), rd: RV_X, immediate: i32) !void {
        if (rd != .zero and fitsInt(immediate, i6)) {
            try rv64.c_li(self.text, rd, @intCast(immediate));
        } else {
            try rv64.li(self.text, rd, immediate);
        }
    }
    
    /// Load Doubleword: ld rd, offset(rs1)
    pub fn ld(self: *@This(), rd: RV_X, rs1: RV_X, offset: i12) !void {
        if (rv64.is3BitReg(rd) and rv64.is3BitReg(rs1) and fitsInt(offset, u8) and @mod(offset, 8) == 0) {
            try rv64.c_ld(self.text, rd, rs1, @intCast(offset));
        } else {
            try rv64.ld(self.text, rd, rs1, offset);
        }
    }
    
    /// Load Word: lw rd, offset(rs1)
    pub fn lw(self: *@This(), rd: RV_X, rs1: RV_X, offset: i12) !void {
        if (rv64.is3BitReg(rd) and rv64.is3BitReg(rs1) and fitsInt(offset, u7) and @mod(offset, 4) == 0) {
            try rv64.c_lw(self.text, rd, rs1, @intCast(offset));
        } else {
            try rv64.lw(self.text, rd, rs1, offset);
        }
    }
    
    /// Load Halfword: lh rd, offset(rs1)
    pub fn lh(self: *@This(), rd: RV_X, rs1: RV_X, offset: i12) !void {
        try rv64.lh(self.text, rd, rs1, offset);
    }
    
    /// Load Byte: lb rd, offset(rs1)
    pub fn lb(self: *@This(), rd: RV_X, rs1: RV_X, offset: i12) !void {
        try rv64.lb(self.text, rd, rs1, offset);
    }
    
    /// Move: mv rd, rs1
    pub fn mv(self: *@This(), rd: RV_X, rs1: RV_X) !void {
        if (rs1 != .zero) {
            try rv64.c_mv(self.text, rd, rs1);
        } else {
            try rv64.mv(self.text, rd, rs1);
        }
    }
    
    /// Multiply Integer: mul rd, rs1, rs2
    pub fn mul(self: *@This(), rd: RV_X, rs1: RV_X, rs2: RV_X) !void {
        // c.mul is only in RISC-V Zcb extension
        try rv64.mul(self.text, rd, rs1, rs2);
    }
    
    /// Store Doubleword: sd rs2, offset(rs1)
    pub fn sd(self: *@This(), rs1: RV_X, rs2: RV_X, offset: i12) !void {
        if (rv64.is3BitReg(rs1) and rv64.is3BitReg(rs2) and fitsInt(offset, u8) and @mod(offset, 8) == 0) {
            try rv64.c_sd(self.text, rs1, rs2, @intCast(offset));
        } else {
            try rv64.sd(self.text, rs1, rs2, offset);
        }
    }
    
    /// Store Word: sw rs2, offset(rs1)
    pub fn sw(self: *@This(), rs1: RV_X, rs2: RV_X, offset: i12) !void {
        if (rv64.is3BitReg(rs1) and rv64.is3BitReg(rs2) and fitsInt(offset, u7) and @mod(offset, 4) == 0) {
            try rv64.c_sw(self.text, rs1, rs2, @intCast(offset));
        } else {
            try rv64.sw(self.text, rs1, rs2, offset);
        }
    }
    
    /// Store Halfword: sh rs2, offset(rs1)
    pub fn sh(self: *@This(), rs1: RV_X, rs2: RV_X, offset: i12) !void {
        try rv64.sh(self.text, rs1, rs2, offset);
    }
    
    /// Store Byte: sb rs2, offset(rs1)
    pub fn sb(self: *@This(), rs1: RV_X, rs2: RV_X, offset: i12) !void {
        try rv64.sb(self.text, rs1, rs2, offset);
    }
    
    /// Subtract: sub rd, rs1, rs2
    pub fn sub(self: *@This(), rd: RV_X, rs1: RV_X, rs2: RV_X) !void {
        if (rd == rs1 and rv64.is3BitReg(rd) and rv64.is3BitReg(rs2)) {
            try rv64.c_sub(self.text, rd, rs2);
        } else {
            try rv64.sub(self.text, rd, rs1, rs2);
        }
    }
    
    /// Return (pseudoinstruction)
    pub fn ret(self: *@This()) !void {
        try rv64.c_jr(self.text, .ra);
    }
};

pub fn compile(allocator: std.mem.Allocator, program: []Instruction, cell_type: CellType) ![]u8 {
    // Our compiled program will be called from Zig with:
    // Argument a0: pointer to memory cells
    // Argument a1: address of read function: u8 read(void)
    // Argument a2: address of print function: void print(value u8)
    // Return value in a0: updated pointer to memory cells
    var rvasm = try Assembler.init(allocator);
    defer rvasm.deinit();
    
    // Stack prologue: Save callee-save registers
    try rvasm.push(&.{ .ra, .s0, .s1, .s2, .s3 });
    
    // Copy our function arguments a0..2 into s0..2
    // Using a0 etc. as temporaries enables more compressed instructions.
    try rvasm.mv(.s0, .a0);
    try rvasm.mv(.s1, .a1);
    try rvasm.mv(.s2, .a2);
    
    // Compile (optimized) Brainfuck opcodes into machine code blocks.
    // Stack forward jump labels to match them with the corresponding
    // back jump when it is encountered.
    var labels = std.ArrayList(usize).init(allocator);
    defer labels.deinit();
    
    const cell_size: isize = switch (cell_type) { .c8 => 1, .c16 => 2, .c32 => 4, .c64 => 8 };
    for (program) |instruction| {
        const cell_off: i12 = @intCast(instruction.off * cell_size);
        switch (instruction.op) {
            .add => |value| {
                try rvasm.loadCell(cell_type, .a0, .s0, cell_off);
                if (fitsInt(value, i12)) {
                    try rvasm.addi(.a0, .a0, @intCast(value));
                } else {
                    try rvasm.li(.a1, @intCast(value));
                    try rvasm.add(.a0, .a0, .a1);
                }
                try rvasm.storeCell(cell_type, .s0, .a0, cell_off);
            },
            .move => |value| {
                const offset = value * cell_size;
                if (fitsInt(offset, i12)) {
                    try rvasm.addi(.s0, .s0, @intCast(offset));
                } else {
                    try rvasm.li(.a0, @intCast(offset));
                    try rvasm.add(.s0, .s0, .a0);
                }
            },
            .print => {
                try rvasm.loadCell(cell_type, .a0, .s0, cell_off);
                try rvasm.jalr(.ra, .s2, 0);
            },
            .read => {
                try rvasm.jalr(.ra, .s1, 0);
                try rvasm.storeCell(cell_type, .s0, .a0, cell_off);
            },
            .jump_forward => {
                try rvasm.loadCell(cell_type, .a0, .s0, cell_off);
                try labels.append(try rvasm.beqz(.a0, 0)); // Target label not yet known
            },
            .jump_back => {
                try rvasm.loadCell(cell_type, .a0, .s0, cell_off);
                const back_label = labels.getLast(); _ = labels.pop(); // Hack to make it work on Zig 0.13 and Zig 0.15
                const here_label = try rvasm.bnez(.a0, back_label);
                rvasm.setTarget(back_label, here_label); // Update label for forward jump
            },
            .set => |value| {
                try rvasm.li(.a0, @intCast(value));
                try rvasm.storeCell(cell_type, .s0, .a0, cell_off);
            },
            .mac => |op| {
                // Load target cell into a0
                // Load target cell address into a2
                const target_off = op.offset * cell_size;
                if (fitsInt(target_off, i12)) {
                    try rvasm.loadCell(cell_type, .a0, .s0, @intCast(target_off));
                } else {
                    try rvasm.li(.a2, @intCast(target_off));
                    try rvasm.add(.a2, .a2, .s0);
                    try rvasm.loadCell(cell_type, .a2, .a0, 0);
                }
                
                // Load current cell into a1
                try rvasm.loadCell(cell_type, .a1, .s0, cell_off);
                
                if (op.multiplier == 1) {
                    // Add current cell value to target cell
                    try rvasm.add(.a0, .a0, .a1);
                } else if (op.multiplier == -1) {
                    // Subtract current cell value from target cell
                    try rvasm.sub(.a0, .a0, .a1);
                } else {
                    // Load multiplier into a3, multiply it with current
                    // cell value and add to target cell value.
                    try rvasm.li(.a3, @intCast(op.multiplier));
                    try rvasm.mul(.a1, .a1, .a3);
                    try rvasm.add(.a0, .a0, .a1);
                }
                
                // Store result in target cell
                if (fitsInt(target_off, i12)) {
                    try rvasm.storeCell(cell_type, .s0, .a0, @intCast(target_off));
                } else {
                    try rvasm.storeCell(cell_type, .a2, .a0, 0);
                }
            },
        }
    }
    
    // Store result (current cell pointer) in a0
    try rvasm.mv(.a0, .s0);
    
    // Stack epilogue (restore saved registers) and return to Zig
    try rvasm.pop(&.{ .ra, .s0, .s1, .s2, .s3 });
    try rvasm.ret();
     
    // Turn assembly labels into actual jumps and link the generated
    // instruction blocks into one conjoined executable.
    return rvasm.assemble();
}
