const std = @import("std");
const builtin = @import("builtin");
const Parser = @import("Parser.zig");
const Arguments = @import("Arguments.zig");
const Instruction = @import("Opcode.zig").Instruction;
const Interpreter = @import("Interpreter.zig").Interpreter;
const InterpreterContext = @import("Interpreter.zig").InterpreterContext;
const ProfilerContext = @import("Interpreter.zig").ProfilerContext;
const Profiler = @import("Profiler.zig");
const Compiler = @import("Compiler.zig");
const Transpiler = @import("Transpiler.zig");
const Memory = @import("Memory.zig");
const IO = @import("IO.zig");

// Brainiac version
pub const version = "0.9.3";

pub fn main() !void {
    // Allocator for everything
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Parse CLI arguments
    var args = try Arguments.parse(allocator);
    defer args.deinit();
    
    // Configure IO
    try IO.init(allocator, args.io_binary, args.io_prompt, args.io_eof);
    defer IO.deinit();
    
    // Windows terminal color support
    _ = std.io.getStdErr().getOrEnableAnsiEscapeSupport();
    
    // Specialize for cell type
    try switch (args.cell_type) {
        .c8  => cellMain(allocator, args,  u8,  "8-bit"),
        .c16 => cellMain(allocator, args, u16, "16-bit"),
        .c32 => cellMain(allocator, args, u32, "32-bit"),
        .c64 => cellMain(allocator, args, u64, "64-bit"),
    };
}

/// Continuation of main with comptime celltype
/// Whether stdin is treated as Brainfuck source code to execute or
/// applications inputs depends on the CLI flags and console mode:
///      infile  --interactive  --interactive infile
/// TTY  inputs  source+inputs  source+inputs
/// Pipe inputs  source         not allowed
pub fn cellMain(allocator: std.mem.Allocator, args: Arguments, comptime T: type, cellinfo: []const u8) !void {
    // Setup protected memory area
    try Memory.enableCustomSEGVHandler();
    var memory = try Memory.Memory(T).init(args.mem_size, args.start_cell);
    defer memory.deinit();
    
    var parser = try Parser.init(allocator);
    defer parser.deinit();
    
    // Welcome and runtime informations
    if (! args.quiet) {
        std.debug.print("Brainiac {s} | ", .{ version });
        switch (args.execution) {
            .interpret => std.debug.print("Interpreter{s}", .{ if (args.profile == null) "" else " + profiler" }),
            .compile   => std.debug.print("Compiler ({s})", .{ Compiler.getNativeArchName() }),
            .transpile => std.debug.print("Transpiler (to C)", .{}),
        }
        std.debug.print(" | -O{d} | {d} {s} cells\n", .{ args.optimization_level, memory.cells.len, cellinfo });
    }
    
    // Read source code from input file or pipe and process it first
    if (args.input_file != null or !std.posix.isatty(std.io.getStdIn().handle)) {
        var source: []u8 = undefined;
        if (args.input_file) |input_file| {
            const file = std.fs.cwd().openFile(input_file, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("Could not read '{s}': File not found.\n", .{ input_file });
                    return;
                }
                return err;
            };
            defer file.close();
            source = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
        } else {
            source = try std.io.getStdIn().reader().readAllAlloc(allocator, std.math.maxInt(usize));
        }
        defer allocator.free(source);
        
        // Parse entire file as one chunk
        if (args.verbose) {
            std.debug.print("Parsing {d} bytes\n", .{ source.len });
        }
        try parser.parse(source);
        try parser.optimize(args.optimization_level, args.verbose);
        const program = try parser.finalize();
        defer allocator.free(program);
        try runProgram(allocator, args, T, &memory, parser.max_off, program);
        if (!args.interactive or !std.posix.isatty(std.io.getStdIn().handle))
            return;
    }
    
    // Interactive mode: Read lines and execute them one after another.
    // Reuse memory cells to maintain the program state.
    var continue_prompt = false;
    while (true) {
        // Before executing the next chunk, check if the current cell is
        // in the allowed area. Otherwise it would be possible to move into
        // the danger zone in one chunk (without triggering SEGV) and move
        // out of the danger zone into Zig memory during the next run,
        // defeating the calculation of the max move/danger zone size.
        if (! memory.checkPointer()) {
            IO.printWarning("Moved out of tape. Here be dragons...");
            return;
        }
        
        // Clear unused program inputs and read source code line instead
        IO.discardLeftoverInput();
        const line = try IO.readSourceLine(allocator, if (continue_prompt) "|" else ">");
        defer allocator.free(line);
        if (line.len == 0)
            return; // stdin closed
        
        // Parse new source line and append tokens to existing program.
        if (args.verbose) {
            std.debug.print("Parsing {d} byte{s}\n", .{ line.len, if (line.len == 1) "" else "s" });
        }
        continue_prompt = false;
        parser.parse(line) catch |err| {
            if (err == Parser.ParseError.UnmatchedJumpForward) {
                // Need to parse more input for an executable chunk
                continue_prompt = true;
                continue;
            }
            if (err == Parser.ParseError.UnmatchedJumpBack) {
                IO.printWarning("Syntax error: Unmatched \"]\": No corresponding opening bracket!");
                return;
            }
            return err;
        };
        
        // Optimize, update sandboxing and execute the program!
        try parser.optimize(args.optimization_level, args.verbose);
        const program = try parser.finalize();
        defer allocator.free(program);
        try runProgram(allocator, args, T, &memory, parser.max_off, program);
    }
}

/// Run finalized program
pub fn runProgram(allocator: std.mem.Allocator, args: Arguments, comptime T: type, memory: *Memory.Memory(T),
                  danger_zone_size: usize, program: []Instruction) !void {
    switch (args.execution) {
        .interpret => {
            try memory.updateDangerZone(danger_zone_size, args.verbose);
            if (args.profile) |profile_file| {
                var profiler = try Profiler.init(allocator, program);
                defer profiler.deinit();
                profiler.start(args.start_cell);
                const ctx = ProfilerContext(T).init(memory, &profiler);
                var interpreter = Interpreter(@TypeOf(ctx)).init(ctx, program);
                try interpreter.run(args.instruction_limit, args.verbose);
                try profiler.report(profile_file, args.input_file);
            } else {
                const ctx = InterpreterContext(T).init(memory);
                var interpreter = Interpreter(@TypeOf(ctx)).init(ctx, program);
                try interpreter.run(args.instruction_limit, args.verbose);
            }
        },
        .compile => {
            const text = Compiler.compile(allocator, program, args.cell_type) catch |err| {
                if (err == Compiler.CompileError.UnsupportedArchitecture) {
                    std.debug.print("Error: Machine architecture {any} not supported!\n", .{ builtin.cpu.arch });
                    return;
                } else if (err == Compiler.CompileError.UnsupportedLargeOffset) {
                    std.debug.print("Error: Application is too big to compile!\nTry using a lower optimization level.\n", .{});
                    return;
                }
                return err;
            };
            defer allocator.free(text);
            if (args.hexdump) {
                try Compiler.hexdump(text);
            } else if (args.output_file) |output_file| {
                // Create and open executable file for writing
                const file = try std.fs.cwd().createFile(output_file,
                    if (comptime builtin.os.tag == .windows) .{} else .{ .mode = 0o755 });
                defer file.close();
                try Compiler.makeStandaloneExecutable(text, file, T, danger_zone_size);
                std.debug.print("Created executable: {s}\n", .{ output_file });
            } else {
                try memory.updateDangerZone(danger_zone_size, args.verbose);
                try Compiler.execute(text, T, memory, args.verbose);
            }
        },
        .transpile => {
            try switch (args.transpile_to) {
                .zig => Transpiler.writeZig(args.cell_type, args.mem_size, args.start_cell, program, std.io.getStdOut().writer()),
                .c => Transpiler.writeC(args.cell_type, args.mem_size, args.start_cell, program, std.io.getStdOut().writer()),
            };
        },
    }
}
