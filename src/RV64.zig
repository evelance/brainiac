//! RISC-V RV64IMC definitions and instruction formatting helpers.
//! Instruction assembly functions append generated machine code
//! to the given array list.

const std = @import("std");

/// RISC-V register size in bits
pub const XLEN = 64;

/// RISC-V register size in bytes
pub const XSZ = 8;

/// RISC-V register aliases
pub const RV_X = enum(u5) {
    zero,       // Hardwired zero
    ra,         // Return address
    sp,         // Stack pointer
    gp,         // Global pointer
    tp,         // Thread pointer
    t0, t1, t2, // Temporary
    s0, s1,     // Saved register
    a0, a1, a2, // Argument/return
    a3, a4, a5, a6, a7,
    s2, s3, s4, s5, s6, s7, s8, s9, s10, s11,
    t3, t4, t5, t6
};

/// RISC-V R-Type instruction format
pub const RV_R = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,
};

/// RISC-V I-Type instruction format
pub const RV_I = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm1: u12,
};

/// RISC-V S-Type instruction format
pub const RV_S = packed struct(u32) {
    opcode: u7,
    imm0_4: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm5_11: u7,
};

/// RISC-V B-Type instruction format
pub const RV_B = packed struct(u32) {
    opcode: u7,
    imm11: u1,
    imm1_4: u4,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm5_10: u6,
    imm12: u1,
};

/// RISC-V U-Type instruction format
pub const RV_U = packed struct(u32) {
    opcode: u7,
    rd: u5,
    imm12_31: u20,
};

/// RISC-V J-Type instruction format
pub const RV_J = packed struct(u32) {
    opcode: u7,
    rd: u5,
    imm12_19: u8,
    imm11: u1,
    imm1_10: u10,
    imm20: u1,
};

/// RISC-V CR-Type (compressed register) instruction format
pub const RV_CR = packed struct(u16) {
    op: u2,
    rs2: u5,
    rd_rs1: u5,
    funct4: u4,
};

/// RISC-V CI-Type (compressed immediate) instruction format
pub const RV_CI = packed struct(u16) {
    op: u2,
    imm0_4: u5,
    rd_rs1: u5,
    imm5: u1,
    funct3: u3,
};

/// RISC-V CL-Type (compressed load) instruction format
pub const RV_CL = packed struct(u16) {
    op: u2,
    rd_: u3,
    imm_a1: u1,
    imm_a2: u1,
    rs1_: u3,
    imm_b: u3,
    funct3: u3,
};

/// RISC-V CS-Type (compressed store) instruction format
pub const RV_CS = packed struct(u16) {
    op: u2,
    rs2_: u3,
    imm_a: u1,
    imm_b: u1,
    rs1_: u3,
    imm_c: u3,
    funct3: u3,
};

/// RISC-V CJ-Type (compressed jump) instruction format
pub const RV_CJ = packed struct(u16) {
    op: u2,
    imm5: u1,
    imm1_3: u3,
    imm7: u1,
    imm6: u1,
    imm10: u1,
    imm8_9: u2,
    imm4: u1,
    imm11: u1,
    funct3: u3,
};

/// RISC-V CA-Type (compressed arithmetic) instruction format
pub const RV_CA = packed struct(u16) {
    op: u2,
    rs2_: u3,
    funct2: u2,
    rsd_rs1_: u3,
    funct6: u6,
};

/// RISC-V CB-Type (compressed branch) instruction format
pub const RV_CB = packed struct(u16) {
    op: u2,
    offset5: u1,
    offset1_2: u2,
    offset6_7: u2,
    rsd_rs1_: u3,
    offset3_4: u2,
    offset8: u1,
    funct3: u3,
};

/// Split 32-bit signed immediate into upper 20 and lower 12 bits.
pub fn offsetHiLo(immediate: i32) struct { hi: i32, lo: i12 } {
    const lo: i12 = @truncate(immediate);
    const hi = immediate - lo;
    return .{ .hi = hi, .lo = lo };
}

/// Checks if given register is one of the 8 registers that can
/// be used with compressed instructions like CIW/CL/CS/CA/CB.
/// Allowed registers are: s0, s1, a0, a1, a2, a3, a4, a5.
pub fn is3BitReg(reg: RV_X) bool {
    return @intFromEnum(reg) >= 8 and @intFromEnum(reg) <= 15;
}

/// Append to given .text data
fn appendInstruction(text: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writePackedInt(T, &buf, 0, value, std.builtin.Endian.little);
    try text.appendSlice(&buf);
}

/// Add (compressed): c.add rd, rs2 -> add rd, rd, rs2
pub fn c_add(text: *std.ArrayList(u8), rd: RV_X, rs2: RV_X) !void {
    std.debug.assert(rd != .zero);
    std.debug.assert(rs2 != .zero);
    const ins = RV_CR {
        .op = 0x2,
        .rs2 = @intFromEnum(rs2),
        .rd_rs1 = @intFromEnum(rd),
        .funct4 = 0x9,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Add Immediate (compressed): c.addi rd, nzimmediate -> addi rd, rd, nzimmediate
pub fn c_addi(text: *std.ArrayList(u8), rd: RV_X, nzimmediate: i6) !void {
    std.debug.assert(rd != .zero);
    std.debug.assert(nzimmediate != 0);
    const imm: u6 = @bitCast(nzimmediate);
    const ins = RV_CI {
        .op = 0x1,
        .imm0_4 = @truncate(imm),
        .rd_rs1 = @intFromEnum(rd),
        .imm5 = @truncate(imm >> 5),
        .funct3 = 0x0,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Branch if Equal to Zero (compressed): c.beqz rs1', offset -> beq rs1, x0, offset
pub fn c_beqz(text: *std.ArrayList(u8), rs1: RV_X, offset: i9) !void {
    std.debug.assert(is3BitReg(rs1));
    std.debug.assert(@mod(offset, 2) == 0);
    const imm: u9 = @bitCast(offset);
    const ins = RV_CB {
        .op = 0x1,
        .offset5 = @truncate(imm >> 5),
        .offset1_2 = @truncate(imm >> 1),
        .offset6_7 = @truncate(imm >> 6),
        .rsd_rs1_ = @truncate(@intFromEnum(rs1) - 8),
        .offset3_4 = @truncate(imm >> 3),
        .offset8 = @truncate(imm >> 8),
        .funct3 = 0x6,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Branch if Not Equal to Zero (compressed): c.bnez rs1', offset -> bne rs1, x0, offset
pub fn c_bnez(text: *std.ArrayList(u8), rs1: RV_X, offset: i9) !void {
    std.debug.assert(is3BitReg(rs1));
    std.debug.assert(@mod(offset, 2) == 0);
    const imm: u9 = @bitCast(offset);
    const ins = RV_CB {
        .op = 0x1,
        .offset5 = @truncate(imm >> 5),
        .offset1_2 = @truncate(imm >> 1),
        .offset6_7 = @truncate(imm >> 6),
        .rsd_rs1_ = @truncate(@intFromEnum(rs1) - 8),
        .offset3_4 = @truncate(imm >> 3),
        .offset8 = @truncate(imm >> 8),
        .funct3 = 0x7,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Load Doubleword (compressed): c.ld rd', offset(rs1')
pub fn c_ld(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: u8) !void {
    std.debug.assert(is3BitReg(rd));
    std.debug.assert(is3BitReg(rs1));
    std.debug.assert(@mod(offset, 8) == 0);
    const ins = RV_CL {
        .op = 0x0,
        .rd_ = @truncate(@intFromEnum(rd) - 8),
        .imm_a1 = @truncate(offset >> 6),
        .imm_a2 = @truncate(offset >> 7),
        .rs1_ = @truncate(@intFromEnum(rs1) - 8),
        .imm_b = @truncate(offset >> 3),
        .funct3 =  0x3,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Load Word (compressed): c.lw rd', offset(rs1')
pub fn c_lw(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: u7) !void {
    std.debug.assert(is3BitReg(rd));
    std.debug.assert(is3BitReg(rs1));
    std.debug.assert(@mod(offset, 4) == 0);
    const ins = RV_CL {
        .op = 0x0,
        .rd_ = @truncate(@intFromEnum(rd) - 8),
        .imm_a1 = @truncate(offset >> 6),
        .imm_a2 = @truncate(offset >> 2),
        .rs1_ = @truncate(@intFromEnum(rs1) - 8),
        .imm_b = @truncate(offset >> 3),
        .funct3 =  0x2,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Load Immediate (compressed): c.li rd, immediate
pub fn c_li(text: *std.ArrayList(u8), rd: RV_X, immediate: i6) !void {
    std.debug.assert(rd != .zero);
    const imm: u6 = @bitCast(immediate);
    const ins = RV_CI {
        .op = 0x1,
        .imm0_4 = @truncate(imm),
        .rd_rs1 = @intFromEnum(rd),
        .imm5 = @truncate(imm >> 5),
        .funct3 = 0x2,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Move (compressed): c.mv rd, rs2 -> add rd, x0, rs2
pub fn c_mv(text: *std.ArrayList(u8), rd: RV_X, rs2: RV_X) !void {
    std.debug.assert(rs2 != .zero);
    const ins = RV_CR {
        .op = 0x2,
        .rs2 = @intFromEnum(rs2),
        .rd_rs1 = @intFromEnum(rd),
        .funct4 = 0x8,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// NOP (compressed): c.nop -> c.addi x0,1
pub fn c_nop(text: *std.ArrayList(u8)) !void {
    const imm: u6 = 1;
    const ins = RV_CI {
        .op = 0x1,
        .imm0_4 = @truncate(imm),
        .rd_rs1 = @intFromEnum(RV_X.zero),
        .imm5 = @truncate(imm >> 5),
        .funct3 = 0x0,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Store Doubleword (compressed): c.sd rs2', offset(rs1')
pub fn c_sd(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: u8) !void {
    std.debug.assert(is3BitReg(rs1));
    std.debug.assert(is3BitReg(rs2));
    std.debug.assert(@mod(offset, 8) == 0);
    const ins = RV_CS {
        .op = 0x0,
        .rs2_ = @truncate(@intFromEnum(rs2) - 8),
        .imm_a = @truncate(offset >> 6),
        .imm_b = @truncate(offset >> 7),
        .rs1_ = @truncate(@intFromEnum(rs1) - 8),
        .imm_c = @truncate(offset >> 3),
        .funct3 =  0x7,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Store Word (compressed): c.sw rs2', offset(rs1')
pub fn c_sw(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: u7) !void {
    std.debug.assert(is3BitReg(rs1));
    std.debug.assert(is3BitReg(rs2));
    std.debug.assert(@mod(offset, 4) == 0);
    const ins = RV_CS {
        .op = 0x0,
        .rs2_ = @truncate(@intFromEnum(rs2) - 8),
        .imm_a = @truncate(offset >> 6),
        .imm_b = @truncate(offset >> 2),
        .rs1_ = @truncate(@intFromEnum(rs1) - 8),
        .imm_c = @truncate(offset >> 3),
        .funct3 =  0x6,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Subtract (compressed): c.sub rd', rs2' -> sub rd', rd', rs2'
pub fn c_sub(text: *std.ArrayList(u8), rd: RV_X, rs2: RV_X) !void {
    std.debug.assert(is3BitReg(rd));
    std.debug.assert(is3BitReg(rs2));
    const ins = RV_CA {
        .op = 0x1,
        .rs2_ = @truncate(@intFromEnum(rs2) - 8),
        .funct2 = 0x0,
        .rsd_rs1_ = @truncate(@intFromEnum(rd) - 8),
        .funct6 = 0x23,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Jump (compressed): c.j offset -> jal x0, offset
pub fn c_j(text: *std.ArrayList(u8), offset: i12) !void {
    std.debug.assert(@mod(offset, 2) == 0);
    const imm: u12 = @bitCast(offset);
    const ins = RV_CJ {
        .op = 0x1,
        .imm5 = @truncate(imm >> 5),
        .imm1_3 = @truncate(imm >> 1),
        .imm7 = @truncate(imm >> 7),
        .imm6 = @truncate(imm >> 6),
        .imm10 = @truncate(imm >> 10),
        .imm8_9 = @truncate(imm >> 8),
        .imm4 = @truncate(imm >> 4),
        .imm11 = @truncate(imm >> 11),
        .funct3 = 0x5,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Jump And Link Register (compressed): c.jalr rs1 -> jalr x1, 0(rs1)
pub fn c_jalr(text: *std.ArrayList(u8), rs1: RV_X) !void {
    std.debug.assert(rs1 != .zero);
    const ins = RV_CR {
        .op = 0x2,
        .rs2 = 0x0,
        .rd_rs1 = @intFromEnum(rs1),
        .funct4 = 0x9,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Jump Register (compressed): c.jr rs1 -> jalr x0, 0(rs1)
pub fn c_jr(text: *std.ArrayList(u8), rs1: RV_X) !void {
    std.debug.assert(rs1 != .zero);
    const ins = RV_CR {
        .op = 0x2,
        .rs2 = 0x0,
        .rd_rs1 = @intFromEnum(rs1),
        .funct4 = 0x8,
    };
    try appendInstruction(text, u16, @bitCast(ins));
}

/// Add: add rd, rs1, rs2
pub fn add(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, rs2: RV_X) !void {
    const ins = RV_R {
        .opcode = 0x33,
        .rd = @intFromEnum(rd),
        .funct3 = 0x0,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .funct7 = 0x0,
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Add Immediate: addi rd, rs1, immediate
pub fn addi(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, immediate: i12) !void {
    const ins = RV_I {
        .opcode = 0x13,
        .rd = @intFromEnum(rd),
        .funct3 = 0,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(immediate),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Add Upper Immediate to PC: auipc rd, offset
pub fn auipc(text: *std.ArrayList(u8), rd: RV_X, offset: i32) !void {
    const imm: u32 = @bitCast(offset);
    const ins = RV_U {
        .opcode = 0x17,
        .rd = @intFromEnum(rd),
        .imm12_31 = @truncate(imm >> 12),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Branch if Equal: beq rs1, rs2, offset
pub fn beq(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: i13) !void {
    const imm: u13 = @bitCast(offset);
    const ins = RV_B {
        .opcode = 0x63,
        .imm11 = @truncate(imm >> 11),
        .imm1_4 = @truncate(imm >> 1),
        .funct3 = 0x0,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .imm5_10 = @truncate(imm >> 5),
        .imm12 = @truncate(imm >> 12),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Branch if Not Equal: bne rs1, rs2, offset
pub fn bne(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: i13) !void {
    const imm: u13 = @bitCast(offset);
    const ins = RV_B {
        .opcode = 0x63,
        .imm11 = @truncate(imm >> 11),
        .imm1_4 = @truncate(imm >> 1),
        .funct3 = 0x1,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .imm5_10 = @truncate(imm >> 5),
        .imm12 = @truncate(imm >> 12),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Doubleword: ld rd, offset(rs1)
pub fn ld(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x3,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Word: lw rd, offset(rs1)
pub fn lw(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x2,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Word Unsigned: lwu rd, offset(rs1)
pub fn lwu(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x6,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Halfword: lh rd, offset(rs1)
pub fn lh(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x1,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Halfword Unsigned: lhu rd, offset(rs1)
pub fn lhu(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x5,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Byte: lb rd, offset(rs1)
pub fn lb(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x0,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Byte Unsigned: lbu rd, offset(rs1)
pub fn lbu(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x3,
        .rd = @intFromEnum(rd),
        .funct3 = 0x4,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Load Immediate
pub fn li(text: *std.ArrayList(u8), rd: RV_X, immediate: i32) !void {
    const hi_lo = offsetHiLo(immediate);
    if (hi_lo.hi != 0) {
        try lui(text, rd, hi_lo.hi);
        try addi(text, rd, rd, hi_lo.lo);
    } else {
        try addi(text, rd, .zero, hi_lo.lo);
    }
}

/// Load Upper Immediate: lui rd, immediate
pub fn lui(text: *std.ArrayList(u8), rd: RV_X, immediate: i32) !void {
    const imm: u32 = @bitCast(immediate);
    const ins = RV_U {
        .opcode = 0x37,
        .rd = @intFromEnum(rd),
        .imm12_31 = @truncate(imm >> 12),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Multiply Integer: mul rd, rs1, rs2
pub fn mul(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, rs2: RV_X) !void {
    const ins = RV_R {
        .opcode = 0x33,
        .rd = @intFromEnum(rd),
        .funct3 = 0x0,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .funct7 = 0x1,
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Move (pseudoinstruction): mv rd, rs1 -> addi rd,rs1,0
pub fn mv(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X) !void {
    try addi(text, rd, rs1, 0);
}

/// NOP (pseudoinstruction): nop -> addi x0,x0,0
pub fn nop(text: *std.ArrayList(u8)) !void {
    try addi(text, .zero, .zero, 0);
}

/// Subtract: sub rd, rs1, rs2
pub fn sub(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, rs2: RV_X) !void {
    const ins = RV_R {
        .opcode = 0x33,
        .rd = @intFromEnum(rd),
        .funct3 = 0x0,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .funct7 = 0x20,
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Store Byte: sb rs2, offset(rs1)
pub fn sb(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: i12) !void {
    const imm: u12 = @bitCast(offset);
    const ins = RV_S {
        .opcode = 0x23,
        .imm0_4 = @truncate(imm),
        .funct3 = 0x0,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .imm5_11 = @truncate(imm >> 5),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Store Halfword: sh rs2, offset(rs1)
pub fn sh(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: i12) !void {
    const imm: u12 = @bitCast(offset);
    const ins = RV_S {
        .opcode = 0x23,
        .imm0_4 = @truncate(imm),
        .funct3 = 0x1,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .imm5_11 = @truncate(imm >> 5),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Store Word: sw rs2, offset(rs1)
pub fn sw(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: i12) !void {
    const imm: u12 = @bitCast(offset);
    const ins = RV_S {
        .opcode = 0x23,
        .imm0_4 = @truncate(imm),
        .funct3 = 0x2,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .imm5_11 = @truncate(imm >> 5),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Store Doubleword: sd rs2, offset(rs1)
pub fn sd(text: *std.ArrayList(u8), rs1: RV_X, rs2: RV_X, offset: i12) !void {
    const imm: u12 = @bitCast(offset);
    const ins = RV_S {
        .opcode = 0x23,
        .imm0_4 = @truncate(imm),
        .funct3 = 0x3,
        .rs1 = @intFromEnum(rs1),
        .rs2 = @intFromEnum(rs2),
        .imm5_11 = @truncate(imm >> 5),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Jump And Link: jal rd, offset
pub fn jal(text: *std.ArrayList(u8), rd: RV_X, offset: i21) !void {
    const imm: u21 = @bitCast(offset);
    const ins = RV_J {
        .opcode = 0x6f,
        .rd = @intFromEnum(rd),
        .imm12_19 = @truncate(imm >> 12),
        .imm11 = @truncate(imm >> 11),
        .imm1_10 = @truncate(imm >> 1),
        .imm20 = @truncate(imm >> 20),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Jump And Link Register: jalr rd, offset(rs1)
pub fn jalr(text: *std.ArrayList(u8), rd: RV_X, rs1: RV_X, offset: i12) !void {
    const ins = RV_I {
        .opcode = 0x67,
        .rd = @intFromEnum(rd),
        .funct3 = 0,
        .rs1 = @intFromEnum(rs1),
        .imm1 = @bitCast(offset),
    };
    try appendInstruction(text, u32, @bitCast(ins));
}

/// Call far-away subroutine (pseudoinstruction)
pub fn call(text: *std.ArrayList(u8), offset: i32) !void {
    const hi_lo = offsetHiLo(offset);
    try auipc(text, .ra, hi_lo.hi);
    try jalr(text, .ra, .ra, hi_lo.lo);
}

/// Return (pseudoinstruction) -> jalr x0, 0(x1)
pub fn ret(text: *std.ArrayList(u8)) !void {
    try jalr(text, .zero, .ra, 0);
}
