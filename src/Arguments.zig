//! CLI argument parsing and default values

const std = @import("std");
const main = @import("main.zig");
const CellType = @import("Memory.zig").CellType;

allocator: std.mem.Allocator,
/// Path to input file or null for stdin
input_file: ?[]u8,
execution: enum {
    interpret,
    compile,
    transpile,
},
quiet: bool,
verbose: bool,
interactive: bool,
io_binary: bool,
io_prompt: bool,
io_eof: u8,
optimization_level: u8,
instruction_limit: ?usize,
/// Path for profile output file or null for no profiling
profile: ?[]u8,
hexdump: bool,
cell_type: CellType,
mem_size: usize,
start_cell: usize,

/// Parse command line arguments. Exits on error or help.
pub fn parse(allocator: std.mem.Allocator) !@This() {
    var args: @This() = .{
        .allocator = allocator,
        .input_file = null,
        .execution = .interpret,
        .quiet = false,
        .verbose = false,
        .interactive = false,
        .io_binary = false,
        .io_prompt = false,
        .io_eof = 0x00,
        .optimization_level = 4,
        .instruction_limit = null,
        .profile = null,
        .hexdump = false,
        .cell_type = .c8,
        .mem_size = 1_000_000,
        .start_cell = 500_000,
    };
    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();
    var profile = false;
    var skip_arg0 = true;
    while (argv.next()) |arg| {
        if (skip_arg0) {
            skip_arg0 = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(@embedFile("help.txt"), .{ main.version });
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("Brainiac {s}\n", .{ main.version });
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "--interpret")) {
            args.execution = .interpret;
        } else if (std.mem.eql(u8, arg, "--compile")) {
            args.execution = .compile;
        } else if (std.mem.eql(u8, arg, "--transpile")) {
            args.execution = .transpile;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            profile = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            args.interactive = true;
        } else if (std.mem.eql(u8, arg, "--io.binary")) {
            args.io_binary = true;
        } else if (std.mem.eql(u8, arg, "--io.prompt")) {
            args.io_prompt = true;
        } else if (std.mem.startsWith(u8, arg, "--io.eof=")) {
            const param = arg[9..];
            args.io_eof = try std.fmt.parseUnsigned(u8, param, 16);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            args.quiet = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--limit=")) {
            const param = arg[8..];
            args.instruction_limit = try std.fmt.parseUnsigned(usize, param, 0);
        } else if (std.mem.startsWith(u8, arg, "--cell=")) {
            const param = arg[7..];
            if (std.mem.eql(u8, param, "8")) {
                args.cell_type = .c8;
            } else if (std.mem.eql(u8, param, "16")) {
                args.cell_type = .c16;
            } else if (std.mem.eql(u8, param, "32")) {
                args.cell_type = .c32;
            } else if (std.mem.eql(u8, param, "64")) {
                args.cell_type = .c64;
            } else {
                std.debug.print("Invalid cell type!\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--memory=")) {
            const param = arg[9..];
            args.mem_size = try std.fmt.parseUnsigned(usize, param, 0);
            args.start_cell = args.mem_size / 2;
        } else if (std.mem.eql(u8, arg, "--hexdump")) {
            args.hexdump = true;
        } else if (std.mem.eql(u8, arg, "-O0")) {
            args.optimization_level = 0;
        } else if (std.mem.eql(u8, arg, "-O1")) {
            args.optimization_level = 1;
        } else if (std.mem.eql(u8, arg, "-O2")) {
            args.optimization_level = 2;
        } else if (std.mem.eql(u8, arg, "-O3")) {
            args.optimization_level = 3;
        } else if (std.mem.eql(u8, arg, "-O4")) {
            args.optimization_level = 4;
        } else if (arg.len > 0 and arg[0] == '-') {
            // Disallow unknown arguments
            std.debug.print("Unknown argument '{s}'! (missing parameter value?)\n", .{ arg });
            std.process.exit(1);
        } else {
            // First positional argument is input file name
            if (args.input_file == null) {
                args.input_file = try allocator.dupe(u8, arg);
            } else {
                std.debug.print("Only one input file allowed.\n", .{});
                std.process.exit(1);
            }
        }
    }
    
    // Extra checks
    if (profile) {
        try args.setProfileFile();
    }
    if (args.input_file == null) {
        args.interactive = true;
    }
    if (args.input_file != null and args.interactive and !std.posix.isatty(std.io.getStdIn().handle)) {
        std.debug.print("Interactive mode only works with a TTY (not pipes)!\n", .{});
        std.process.exit(1);
    }
    if (args.instruction_limit != null and args.execution != .interpret) {
        std.debug.print("Execution limit only works in interpreter mode!\n", .{});
        std.process.exit(1);
    }
    if (args.profile != null and args.execution != .interpret) {
        std.debug.print("Can only profile in interpreter mode!\n", .{});
        std.process.exit(1);
    }
    if (args.interactive and args.profile != null) {
        std.debug.print("Profiler not available in interactive mode!\n", .{});
        std.process.exit(1);
    }
    if (args.interactive and args.execution == .transpile) {
        std.debug.print("Transpiler not available in interactive mode!\n", .{});
        std.process.exit(1);
    }
    if (args.mem_size == 0) {
        std.debug.print("Memory size must be at least one cell!\n", .{});
        std.process.exit(1);
    }
    return args;
}

pub fn deinit(self: *@This()) void {
    if (self.input_file) |_f| self.allocator.free(_f);
    if (self.profile) |_f| self.allocator.free(_f);
}

pub fn setProfileFile(self: *@This()) !void {
    const profile = if (self.input_file) |f|
        try std.mem.concat(self.allocator, u8, &[_][]const u8 { f, ".profile.htm" })
     else
        try self.allocator.dupe(u8, "profile.htm");
    if (self.profile) |_f| self.allocator.free(_f);
    self.profile = profile;
}
