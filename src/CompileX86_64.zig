//! Compile (optimized) Brainfuck opcodes into x86_64 machine code.
//! Generates a function adhering to the SYS-V calling convention.

const std = @import("std");
const Instruction = @import("Opcode.zig").Instruction;
const CellType = @import("Memory.zig").CellType;

fn fitsInt(value: anytype, comptime T: type) bool {
    return value >= std.math.minInt(T) and value <= std.math.maxInt(T);
}

/// Crude x86 instruction stitching
const Assembler = struct {
    allocator: std.mem.Allocator,
    /// Already generated x86 instructions
    text: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .allocator = allocator,
            .text = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.text.deinit();
    }
    
    /// Register names
    const Register = enum {
        // 64-bit
        rax, rcx, rdx, rbx, rsi, rdi, rsp, rbp, r8, r9, r10, r11, r12, r13, r14, r15,
        // 32-bit
        eax, ecx, edx, ebx, esi, edi, esp, ebp, r8d, r9d, r10d, r11d, r12d, r13d, r14d, r15d,
        // 16-bit
        ax, cx, dx, bx, si, di, sp, bp, r8w, r9w, r10w, r11w, r12w, r13w, r14w, r15w,
        // 8-bit
        al, cl, dl, bl, sil, dil, spl, bpl, r8b, r9b, r10b, r11b, r12b, r13b, r14b, r15b,
    };
    
    /// Decrement stack pointer and store operand on top of stack.
    pub fn push(self: *@This(), reg: Register) !void {
        const op: u8 = switch (reg) {
            .rax => 0x50, .rcx => 0x51, .rdx => 0x52, .rbx => 0x53,
            .rsp => 0x54, .rbp => 0x55, .rsi => 0x56, .rdi => 0x57,
            .r12 => 0x54, .r13 => 0x55, .r14 => 0x56, .r15 => 0x57,
            else => unreachable, // Not implemented
        };
        if (reg == .r12 or reg == .r13 or reg == .r14 or reg == .r15) {
            try self.text.append(0x41);
        }
        try self.text.append(op);
    }
    
    /// Load value on top of stack into operand and increment stack pointer.
    pub fn pop(self: *@This(), reg: Register) !void {
        const op: u8 = switch (reg) {
            .rax => 0x58, .rcx => 0x59, .rdx => 0x5a, .rbx => 0x5b,
            .rsp => 0x5c, .rbp => 0x5d, .rsi => 0x5e, .rdi => 0x5f,
            .r12 => 0x5c, .r13 => 0x5d, .r14 => 0x5e, .r15 => 0x5f,
            else => unreachable, // Not implemented
        };
        if (reg == .r12 or reg == .r13 or reg == .r14 or reg == .r15) {
            try self.text.append(0x41);
        }
        try self.text.append(op);
    }
    
    /// Move register value into another register
    pub fn mov_reg_reg(self: *@This(), dst: Register, src: Register) !void {
        if (dst == .rbp and src == .rdi) {
            try self.text.appendSlice(&[_]u8{ 0x48, 0x89, 0xfd });
        } else if (dst == .rbx and src == .rdx) {
            try self.text.appendSlice(&[_]u8{ 0x48, 0x89, 0xd3 });
        } else if (dst == .r12 and src == .rsi) {
            try self.text.appendSlice(&[_]u8{ 0x49, 0x89, 0xf4 });
        } else if (dst == .rax and src == .rbp) {
            try self.text.appendSlice(&[_]u8{ 0x48, 0x89, 0xe8 });
        } else unreachable; // Not implemented
    }
    
    /// Place return address on stack and jump to address in reg
    pub fn call(self: *@This(), reg: Register) !void {
        if (reg == .rbx) {
            return self.text.appendSlice(&[_]u8{ 0xff, 0xd3 });
        }
        const op: u8 = switch (reg) {
            .r12 => 0xd4, .r13 => 0xd5, .r14 => 0xd6, .r15 => 0xd7,
            else => unreachable, // Not implemented
        };
        try self.text.append(0x41);
        try self.text.append(0xff);
        try self.text.append(op);
    }
    
    /// add    QWORD PTR [rbp+offset],immediate
    pub fn add_QWORD_rbp(self: *@This(), offset: i32, immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x81, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// add    DWORD PTR [rbp+offset],immediate
    pub fn add_DWORD_rbp(self: *@This(), offset: i32, immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x81, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// add    WORD PTR [rbp+offset],immediate
    pub fn add_WORD_rbp(self: *@This(), offset: i32, immediate: i16) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0x81, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i16, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(buf[0..2]);
    }
    
    /// add    BYTE PTR [rbp+offset],immediate
    pub fn add_BYTE_rbp(self: *@This(), offset: i32, immediate: i8) !void {
        try self.text.appendSlice(&[_]u8{ 0x80, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        try self.text.append(@bitCast(immediate));
    }
    
    /// add    rbp,immediate
    pub fn add_rbp(self: *@This(), immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x81, 0xc5 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// add    QWORD PTR [rbp+offset],rax
    pub fn add_rbp_QWORD_rax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x01, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// add    DWORD PTR [rbp+offset],eax
    pub fn add_rbp_DWORD_eax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x01, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// add    WORD PTR [rbp+offset],ax
    pub fn add_rbp_WORD_ax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0x01, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// add    BYTE PTR [rbp+offset],al
    pub fn add_rbp_BYTE_al(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x00, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// sub    QWORD PTR [rbp+offset],rax
    pub fn sub_rbp_QWORD_rax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x29, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// sub    DWORD PTR [rbp+offset],eax
    pub fn sub_rbp_DWORD_eax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x29, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// sub    WORD PTR [rbp+offset],ax
    pub fn sub_rbp_WORD_ax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0x29, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// sub    BYTE PTR [rbp+offset],al
    pub fn sub_rbp_BYTE_al(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x28, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// cmp    QWORD PTR [rbp+offset],immediate
    pub fn cmp_QWORD_rbp(self: *@This(), offset: i32, immediate: u8) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x83, 0xbd });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        try self.text.append(immediate);
    }
    
    /// cmp    DWORD PTR [rbp+offset],immediate
    pub fn cmp_DWORD_rbp(self: *@This(), offset: i32, immediate: u8) !void {
        try self.text.appendSlice(&[_]u8{ 0x83, 0xbd });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        try self.text.append(immediate);
    }
    
    /// cmp    WORD PTR [rbp+offset],immediate
    pub fn cmp_WORD_rbp(self: *@This(), offset: i32, immediate: u8) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0x83, 0xbd });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        try self.text.append(immediate);
    }
    
    /// cmp    BYTE PTR [rbp+offset],immediate
    pub fn cmp_BYTE_rbp(self: *@This(), offset: i32, immediate: u8) !void {
        try self.text.appendSlice(&[_]u8{ 0x80, 0xbd });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        try self.text.append(immediate);
    }
    
    /// je    offset
    pub fn je(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x0f, 0x84 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// jne    offset
    pub fn jne(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x0f, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// movzx  edi,BYTE PTR [rbp+offset]
    pub fn movzx_edi_BYTE(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x0f, 0xb6, 0xbd });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    QWORD PTR [rbp+offset],rax
    pub fn mov_rbp_QWORD_rax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x89, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    DWORD PTR [rbp+offset],eax
    pub fn mov_rbp_DWORD_eax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x89, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    WORD PTR [rbp+offset],ax
    pub fn mov_rbp_WORD_ax(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0x89, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    BYTE PTR [rbp+offset],al
    pub fn mov_rbp_BYTE_al(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x88, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    QWORD PTR [rbp+offset],immediate
    pub fn mov_QWORD_rbp(self: *@This(), offset: i32, immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0xc7, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    DWORD PTR [rbp+offset],immediate
    pub fn mov_DWORD_rbp(self: *@This(), offset: i32, immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0xc7, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    WORD PTR [rbp+offset],immediate
    pub fn mov_WORD_rbp(self: *@This(), offset: i32, immediate: i16) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0xc7, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i16, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(buf[0..2]);
    }
    
    /// mov    BYTE PTR [rbp+offset],immediate
    pub fn mov_BYTE_rbp(self: *@This(), offset: i32, immediate: i8) !void {
        try self.text.appendSlice(&[_]u8{ 0xc6, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        try self.text.append(@bitCast(immediate));
    }
    
    /// imul   rax,QWORD PTR [rbp+offset],immediate
    pub fn imul_rax_QWORD_rbp(self: *@This(), offset: i32, immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x69, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// imul   eax,DWORD PTR [rbp+offset],immediate
    pub fn imul_eax_DWORD_rbp(self: *@This(), offset: i32, immediate: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x69, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// imul   ax,WORD PTR [rbp+offset],immediate
    pub fn imul_ax_WORD_rbp(self: *@This(), offset: i32, immediate: i16) !void {
        try self.text.appendSlice(&[_]u8{ 0x66, 0x69, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
        std.mem.writePackedInt(i16, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(buf[0..2]);
    }
    
    /// mul    BYTE PTR [rbp+offset]
    pub fn mul_al_BYTE_rbp(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0xf6, 0xa5 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    ///  mov    eax,immediate
    pub fn mov_eax(self: *@This(), immediate: i32) !void {
        try self.text.append(0xb8);
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, immediate, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    rax,QWORD PTR [rbp+offset]
    pub fn mov_rax_QWORD_rbp(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x48, 0x8b, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// mov    eax,DWORD PTR [rbp+offset]
    pub fn mov_eax_DWORD_rbp(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x8b, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// movzx  eax,WORD PTR [rbp+offset]
    pub fn movzx_eax_WORD_rbp(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x0f, 0xb7, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// movzx  eax,BYTE PTR [rbp+offset]
    pub fn movzx_eax_BYTE_rbp(self: *@This(), offset: i32) !void {
        try self.text.appendSlice(&[_]u8{ 0x0f, 0xb6, 0x85 });
        var buf: [4]u8 = undefined;
        std.mem.writePackedInt(i32, &buf, 0, offset, std.builtin.Endian.little);
        try self.text.appendSlice(&buf);
    }
    
    /// sub    rsp,0x8
    pub fn sub_rsp_8(self: *@This()) !void {
        try self.text.append(0x48);
        try self.text.append(0x83);
        try self.text.append(0xec);
        try self.text.append(0x08);
    }
    
    /// add    rsp,0x8
    pub fn add_rsp_8(self: *@This()) !void {
        try self.text.append(0x48);
        try self.text.append(0x83);
        try self.text.append(0xc4);
        try self.text.append(0x08);
    }
    
    pub fn ret(self: *@This()) !void {
        try self.text.append(0xc3);
    }
    
    pub fn assemble(self: *@This()) ![]u8 {
        return self.text.toOwnedSlice();
    }
};

pub fn compile(allocator: std.mem.Allocator, program: []Instruction, cell_type: CellType) ![]u8 {
    // Our compiled program will be called from Zig with:
    // Argument in rdi: pointer to memory cells
    // Argument in rsi: address of read function (returns in rax)
    // Argument in rdx: address of print function
    // Return value in rax: updated pointer to memory cells
    var x86asm = try Assembler.init(allocator);
    defer x86asm.deinit();
    
    // Stack prologue: Save callee-save registers that will be used
    try x86asm.push(.rbp); // cell pointer
    try x86asm.push(.rbx); // print function
    try x86asm.push(.r12); // read function
    try x86asm.push(.r13); 
    try x86asm.push(.r14); 
    try x86asm.push(.r15);
    try x86asm.sub_rsp_8(); // Maintain 16-byte stack alignment (call pushes 8 bytes, too!)
    
    // Save program arguments in callee-save registers
    try x86asm.mov_reg_reg(.rbp, .rdi);
    try x86asm.mov_reg_reg(.rbx, .rdx);
    try x86asm.mov_reg_reg(.r12, .rsi);
    
    // Compile (optimized) Brainfuck opcodes into machine code sequence.
    // Save forward jump offsets to patch them when the matching
    // back jump is encountered.
    var jumps = std.ArrayList(usize).init(allocator);
    defer jumps.deinit();
    
    const cell_size: isize = switch (cell_type) { .c8 => 1, .c16 => 2, .c32 => 4, .c64 => 8 };
    for (program) |instruction| {
        const cell_off: i32 = @intCast(instruction.off * cell_size);
        switch (instruction.op) {
            .add => |value| {
                switch (cell_type) {
                    .c8 => try x86asm.add_BYTE_rbp(cell_off, @intCast(value)),
                    .c16 => try x86asm.add_WORD_rbp(cell_off, @intCast(value)),
                    .c32 => try x86asm.add_DWORD_rbp(cell_off, @intCast(value)),
                    .c64 => try x86asm.add_QWORD_rbp(cell_off, @intCast(value)),
                }
            },
            .move => |value| {
                try x86asm.add_rbp(@intCast(value * cell_size));
            },
            .print => {
                try x86asm.movzx_edi_BYTE(cell_off);
                try x86asm.call(.rbx);
            },
            .read => {
                try x86asm.call(.r12);
                switch (cell_type) {
                    .c8 => try x86asm.mov_rbp_BYTE_al(cell_off),
                    .c16 => try x86asm.mov_rbp_WORD_ax(cell_off),
                    .c32 => try x86asm.mov_rbp_DWORD_eax(cell_off),
                    .c64 => try x86asm.mov_rbp_QWORD_rax(cell_off),
                }
            },
            .jump_forward => {
                // Jump forward if cell is zero
                switch (cell_type) {
                    .c8 => try x86asm.cmp_BYTE_rbp(cell_off, 0), // 7 byte
                    .c16 => try x86asm.cmp_WORD_rbp(cell_off, 0), // 8 byte
                    .c32 => try x86asm.cmp_DWORD_rbp(cell_off, 0), // 7 byte
                    .c64 => try x86asm.cmp_QWORD_rbp(cell_off, 0), // 8 byte
                }
                try x86asm.je(0); // 6 byte (offset will be patched later)
                try jumps.append(x86asm.text.items.len);
            },
            .jump_back => {
                const addr_back = jumps.getLast(); _ = jumps.pop(); // Hack to make it work on Zig 0.13 and Zig 0.15
                const addr_here = x86asm.text.items.len;
                
                // Jump back if cell is not zero
                const cmp_start = x86asm.text.items.len;
                switch (cell_type) {
                    .c8 => try x86asm.cmp_BYTE_rbp(cell_off, 0), // 7 byte
                    .c16 => try x86asm.cmp_WORD_rbp(cell_off, 0), // 8 byte
                    .c32 => try x86asm.cmp_DWORD_rbp(cell_off, 0), // 7 byte
                    .c64 => try x86asm.cmp_QWORD_rbp(cell_off, 0), // 8 byte
                }
                const cmp_len = x86asm.text.items.len - cmp_start;
                const forward_leap = (addr_here + cmp_len + 6) - addr_back;
                try x86asm.jne(@intCast(-@as(isize,@intCast(forward_leap)))); // 6 byte
                
                // Patch forward jump address (the 4 bytes before addr_back)
                std.mem.writePackedInt(i32, x86asm.text.items[(addr_back - 4)..], 0, @intCast(forward_leap), std.builtin.Endian.little);
            },
            .set => |value| {
                switch (cell_type) {
                    .c8 => try x86asm.mov_BYTE_rbp(cell_off, @intCast(value)),
                    .c16 => try x86asm.mov_WORD_rbp(cell_off, @intCast(value)),
                    .c32 => try x86asm.mov_DWORD_rbp(cell_off, @intCast(value)),
                    .c64 => try x86asm.mov_QWORD_rbp(cell_off, @intCast(value)),
                }
            },
            .mac => |op| {
                if (op.multiplier == 1 or op.multiplier == -1) {
                    // Load current cell into rax
                    switch (cell_type) {
                        .c8 => try x86asm.movzx_eax_BYTE_rbp(cell_off),
                        .c16 => try x86asm.movzx_eax_WORD_rbp(cell_off),
                        .c32 => try x86asm.mov_eax_DWORD_rbp(cell_off),
                        .c64 => try x86asm.mov_rax_QWORD_rbp(cell_off),
                    }
                } else {
                    // Load current cell into rax and multiply with multiplier
                    switch (cell_type) {
                        .c8 => {
                            std.debug.assert(fitsInt(op.multiplier, i8));
                            try x86asm.mov_eax(@intCast(op.multiplier));
                            try x86asm.mul_al_BYTE_rbp(cell_off); // implicit al
                        },
                        .c16 => try x86asm.imul_ax_WORD_rbp(cell_off, @intCast(op.multiplier)),
                        .c32 => try x86asm.imul_eax_DWORD_rbp(cell_off, @intCast(op.multiplier)),
                        .c64 => try x86asm.imul_rax_QWORD_rbp(cell_off, @intCast(op.multiplier)),
                    }
                }
                
                // Add or subtract rax to target cell
                if (op.multiplier == -1) {
                    switch (cell_type) {
                        .c8 => try x86asm.sub_rbp_BYTE_al(@intCast(op.offset * cell_size)),
                        .c16 => try x86asm.sub_rbp_WORD_ax(@intCast(op.offset * cell_size)),
                        .c32 => try x86asm.sub_rbp_DWORD_eax(@intCast(op.offset * cell_size)),
                        .c64 => try x86asm.sub_rbp_QWORD_rax(@intCast(op.offset * cell_size)),
                    }
                } else {
                    switch (cell_type) {
                        .c8 => try x86asm.add_rbp_BYTE_al(@intCast(op.offset * cell_size)),
                        .c16 => try x86asm.add_rbp_WORD_ax(@intCast(op.offset * cell_size)),
                        .c32 => try x86asm.add_rbp_DWORD_eax(@intCast(op.offset * cell_size)),
                        .c64 => try x86asm.add_rbp_QWORD_rax(@intCast(op.offset * cell_size)),
                    }
                }
            },
        }
    }
    
    // Store result (current cell pointer) in rax
    try x86asm.mov_reg_reg(.rax, .rbp);
    
    // Stack epilogue and return to Zig
    try x86asm.add_rsp_8();
    try x86asm.pop(.r15);
    try x86asm.pop(.r14);
    try x86asm.pop(.r13);
    try x86asm.pop(.r12);
    try x86asm.pop(.rbx);
    try x86asm.pop(.rbp);
    try x86asm.ret();
    
    return x86asm.assemble();
}
