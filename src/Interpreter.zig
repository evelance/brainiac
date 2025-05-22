//! Interpret array of brainfuck instructions/opcodes directly.
//! Since the opcodes are pretty big at 32 bytes, performance
//! is mostly limited by the heavy use of the data cache.

const std = @import("std");
const Instruction = @import("Opcode.zig").Instruction;
const CellType = @import("Memory.zig").CellType;
const Memory = @import("Memory.zig").Memory;
const Profiler = @import("Profiler.zig");
const IO = @import("IO.zig");

/// Simple and direct interpreter.
pub fn InterpreterContext(comptime T: type) type {
    return struct {
        memory: *Memory(T),
        pub fn init(memory: *Memory(T)) @This() {
            return .{
                .memory = memory,
            };
        }
        pub inline fn execute(_: *@This(), _: usize) void { }
        pub inline fn move(self: *@This(), off: isize) void {
            return self.memory.move(off);
        }
        pub inline fn load(self: @This(), off: isize) T {
            return self.memory.load(off);
        }
        pub inline fn store(self: *@This(), off: isize, c: T) void {
            self.memory.store(off, c);
        }
    };
}

/// Interpret opcodes and call profiler at the execution of every
/// opcode to record instruction count and memory usage. This is
/// obviously a lot slower than the direct interpreter.
pub fn ProfilerContext(comptime T: type) type {
    return struct {
        memory: *Memory(T),
        profiler: *Profiler,
        pub fn init(memory: *Memory(T), profiler: *Profiler) @This() {
            return .{
                .memory = memory,
                .profiler = profiler,
            };
        }
        pub inline fn execute(self: *@This(), pc: usize) void {
            self.profiler.*.recordExecute(pc);
        }
        pub inline fn move(self: *@This(), off: isize) void {
            return self.memory.move(off);
        }
        pub inline fn load(self: @This(), off: isize) T {
            const c = self.memory.load(off);
            self.profiler.*.recordMemUse(self.memory.cellIdx(off), @intCast(c));
            return c;
        }
        pub inline fn store(self: *@This(), off: isize, c: T) void {
            self.memory.store(off, c);
            self.profiler.*.recordMemUse(self.memory.cellIdx(off), @intCast(c));
        }
    };
}

/// Interpreter template
pub fn Interpreter(comptime Context: type) type {
    return struct {
        ctx: Context,
        program: []const Instruction,
        /// Program counter
        pc: usize,
        
        pub fn init(ctx: Context, program: []const Instruction) @This() {
            return .{
                .ctx = ctx,
                .program = program,
                .pc = 0,
            };
        }
        
        inline fn step(self: *@This()) void {
            self.ctx.execute(self.pc);
            const ins = self.program[self.pc];
            switch (ins.op) {
                .add => |val| {
                    self.ctx.store(ins.off, @truncate(@as(usize, self.ctx.load(ins.off)) +% @as(usize, @bitCast(val))));
                },
                .move => |val| {
                    self.ctx.move(val);
                },
                .print => {
                    IO.operatorPrint(@truncate(self.ctx.load(ins.off)));
                },
                .read => {
                    self.ctx.store(ins.off, IO.operatorRead());
                },
                .jump_forward => |addr| {
                    if (self.ctx.load(ins.off) == 0) {
                        self.pc = addr;
                    }
                },
                .jump_back => |addr| {
                    if (self.ctx.load(ins.off) != 0) {
                        self.pc = addr;
                    }
                },
                .set => |val| {
                    self.ctx.store(ins.off, @truncate(@as(usize, @bitCast(val))));
                },
                .mac => |op| {
                    self.ctx.store(op.offset, @truncate(@as(usize, self.ctx.load(op.offset)) +%
                        (@as(usize, self.ctx.load(ins.off)) *% @as(usize, @bitCast(op.multiplier)))));
                },
            }
            self.pc += 1;
        }
        
        /// Interpret the program until either completion or until
        /// the specified number of instructions has been executed.
        pub fn run(self: *@This(), limit: ?usize, verbose: bool) !void {
            var timer = try std.time.Timer.start();
            if (limit) |n| {
                var counter: usize = n;
                while (self.pc < self.program.len and counter > 0) {
                    counter -= 1;
                    self.step();
                }
            } else {
                while (self.pc < self.program.len) {
                    self.step();
                }
            }
            const elapsed_ns: f64 = @floatFromInt(timer.read());
            IO.endLine();
            if (verbose) {
                std.debug.print("Execution time: {d:.3}ms\n", .{ elapsed_ns / std.time.ns_per_ms });
            }
        }
    };
}
