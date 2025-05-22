//! Architecture independent compiler setup and runtime
//! resources needed to run the compiled executable.

const std = @import("std");
const builtin = @import("builtin");
const CompileRV64 = @import("CompileRV64.zig");
const CompileX86_64 = @import("CompileX86_64.zig");
const Instruction = @import("Opcode.zig").Instruction;
const Memory = @import("Memory.zig");
const IO = @import("IO.zig");
const CC: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86_64) .SysV else .C;

pub const CompileError = error {
    UnsupportedArchitecture,
};

pub fn getNativeArchName() []const u8 {
    return switch (builtin.cpu.arch) {
        .riscv64 => "RISC-V 64",
        .x86_64 => "x86-64",
        else => "Unsupported", // Interpreter still works, though
    };
}

/// Compile machine code for the native architecture.
/// Caller is responsible to free the returned slice.
pub fn compile(allocator: std.mem.Allocator, program: []Instruction, cell_type: Memory.CellType) ![]u8 {
    return switch (builtin.cpu.arch) {
        .riscv64 => CompileRV64.compile(allocator, program, cell_type),
        .x86_64 => CompileX86_64.compile(allocator, program, cell_type),
        else => CompileError.UnsupportedArchitecture,
    };
}

/// Print hexdump of generated machine code (e.g. to disassemble it)
pub fn hexdump(executable: []const u8) !void {
    var line: usize = 0;
    for (executable) |byte| {
        line += 1;
        if (line >= 32) {
            line = 0;
            std.debug.print("{x:0>2}\n", .{ byte });
        } else {
            std.debug.print("{x:0>2} ", .{ byte });
        }
    }
    std.debug.print("\n", .{});
}

/// Map executable into current address space and run it.
pub fn execute(executable: []const u8, comptime T: type, memory: *Memory.Memory(T), verbose: bool) !void {
    // Request new memory mapping for our .text section.
    const text = try Memory.mapReadWriteMemory(executable.len);
    defer Memory.unmapMemory(text);
    @memcpy(text.ptr, executable);
    if (verbose) {
        std.debug.print(".text section: {d} bytes ({d} bytes used)\n", .{ text.len, executable.len });
    }
    
    // Swap W^X flags for execution
    try Memory.protectMemory(text, .exec);
    
    // Execute our compiled program!
    const compiled_function:
        *fn ([*]T, *const fn () callconv(CC) u8, *const fn (u8) callconv(CC) void) callconv(CC) [*]T
        = @ptrCast(text.ptr);
    var timer = try std.time.Timer.start();
    const cell_pointer = compiled_function(memory.getPointer(), operatorRead, operatorPrint);
    const elapsed_ns: f64 = @floatFromInt(timer.read());
    IO.endLine();
    if (verbose) {
        std.debug.print("Execution time: {d:.3}ms\n", .{ elapsed_ns / std.time.ns_per_ms });
    }
    
    // Update current cell pointer
    memory.setPointer(cell_pointer);
}

/// Called by the executable for read operations: ,
/// Just a wrapper for the desired calling convention.
fn operatorRead() callconv(CC) u8 {
    return IO.operatorRead();
}

/// Called by the executable for print operations: .
/// Just a wrapper for the desired calling convention.
fn operatorPrint(value: u8) callconv(CC) void {
    IO.operatorPrint(value);
}
