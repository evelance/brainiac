//! Supporting runtime for compiled standalone Brainfuck programs.
//! Not directly part of the main executable!
//! This is the entry point for standalone Brainfuck programs.
//! It will be compiled into a "template" executable and stored
//! in the main application as a BLOB.

const std = @import("std");
const builtin = @import("builtin");
const Memory = @import("Memory.zig");
const Compiler = @import("Compiler.zig");
const IO = @import("IO.zig");

pub fn main() !void {
    // Allocator for everything
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Parse (simplified) CLI arguments
    var args = try StandaloneArguments.parse(allocator);
    defer args.deinit();
    
    // Configure IO
    try IO.init(allocator, args.io_binary, args.io_prompt, args.io_eof);
    defer IO.deinit();
    
    // Windows terminal color support
    _ = std.io.getStdErr().getOrEnableAnsiEscapeSupport();
    
    // Read the size of the user application, the required danger
    // zone size, the cell type and the application itself from
    // the end of the file.
    const file = try std.fs.cwd().openFile(args.arg0.?, .{});
    defer file.close();
    const data = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    
    const executable_size = std.mem.readInt(u64, data[data.len - 8..][0..8], std.builtin.Endian.little);
    const danger_zone_size = std.mem.readInt(u64, data[data.len - 16..][0..8], std.builtin.Endian.little);
    const cell_bits = data[data.len - 17];
    const executable = data[data.len - 17 - executable_size..][0..executable_size];
    return switch (cell_bits) {
        8 => execute(u8, executable, args, @intCast(danger_zone_size)),
        16 => execute(u16, executable, args, @intCast(danger_zone_size)),
        32 => execute(u32, executable, args, @intCast(danger_zone_size)),
        64 => execute(u64, executable, args, @intCast(danger_zone_size)),
        else => {
            std.debug.print("Corrupted file: Invalid cell size: {d}\n", .{ cell_bits });
            std.process.exit(1);
            unreachable;
        },
    };
}

/// Setup memory area and execute the attached Brainfuck code! 
fn execute(T: type, executable: []u8, args: StandaloneArguments, danger_zone_size: usize) !void {
    try Memory.enableCustomSEGVHandler();
    var memory = try Memory.Memory(T).init(args.mem_size, args.start_cell);
    defer memory.deinit();
    try memory.updateDangerZone(danger_zone_size, false);
    try Compiler.execute(executable, T, &memory, false);
}

/// Simplified version of Arguments.zig
const StandaloneArguments = struct {
    allocator: std.mem.Allocator,
    arg0: ?[]u8,
    io_binary: bool,
    io_prompt: bool,
    io_eof: u8,
    mem_size: usize,
    start_cell: usize,
    
    pub fn parse(allocator: std.mem.Allocator) !@This() {
        var args: @This() = .{
            .allocator = allocator,
            .arg0 = null,
            .io_binary = false,
            .io_prompt = false,
            .io_eof = 0x00,
            .mem_size = 1_000_000,
            .start_cell = 500_000,
        };
        var argv = try std.process.argsWithAllocator(allocator);
        defer argv.deinit();
        var is_arg0 = true;
        while (argv.next()) |arg| {
            if (is_arg0) {
                is_arg0 = false;
                args.arg0 = try allocator.dupe(u8, arg);
                continue;
            }
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                std.debug.print(@embedFile("templates/help_standalone.txt"), .{});
                std.process.exit(1);
            } else if (std.mem.eql(u8, arg, "--io.binary")) {
                args.io_binary = true;
            } else if (std.mem.eql(u8, arg, "--io.prompt")) {
                args.io_prompt = true;
            } else if (std.mem.startsWith(u8, arg, "--io.eof=")) {
                const param = arg[9..];
                args.io_eof = try std.fmt.parseUnsigned(u8, param, 16);
            } else if (std.mem.startsWith(u8, arg, "--memory=")) {
                const param = arg[9..];
                args.mem_size = try std.fmt.parseUnsigned(usize, param, 0);
                args.start_cell = args.mem_size / 2;
            } else {
                // Disallow unknown arguments
                std.debug.print("Unknown argument '{s}'! (missing parameter value?)\n", .{ arg });
                std.process.exit(1);
            }
        }
        
        // Extra checks
        if (args.mem_size == 0) {
            std.debug.print("Memory size must be at least one cell!\n", .{});
            std.process.exit(1);
        }
        return args;
    }
    
    pub fn deinit(self: *@This()) void {
        if (self.arg0) |str| self.allocator.free(str);
    }
};
