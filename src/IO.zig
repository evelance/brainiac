//! Brainfuck I/O helper functions

const std = @import("std");

var isTTY: bool = true;
var print_binary: bool = false;
var read_prompt: bool = true;
var read_eof_char: u8 = 0x00;
var last_printed: ?u8 = null;
var signaled_eof: bool = false;
var read_buffer: std.ArrayList(u8) = undefined;
var read_used: usize = 0;

pub fn init(allocator: std.mem.Allocator, binary: bool, prompt: bool, eof: u8) !void {
    isTTY = std.posix.isatty(std.io.getStdIn().handle);
    print_binary = binary;
    read_prompt = prompt;
    read_eof_char = eof;
    read_buffer = std.ArrayList(u8).init(allocator);
}

pub fn deinit() void {
    read_buffer.deinit();
}

pub fn readSourceLine(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    // Colored indicator to show user this input is not part
    // the Brainfuck application currently running.
    std.debug.print("\x1b[33;1m{s}\x1b[0m ", .{ prompt });
    
    var line = std.ArrayList(u8).init(allocator);
    errdefer line.deinit();
    while (true) {
        var buffer: [16384]u8 = undefined;
        const len = try std.io.getStdIn().reader().read(&buffer);
        if (len == 0) {
            // EOF - finish prompt line
            std.debug.print("\n", .{});
            break;
        }
        try line.appendSlice(buffer[0..len]);
        if (buffer[len - 1] == '\n')
            break; // Line finished
    }
    return line.toOwnedSlice();
}

pub fn discardLeftoverInput() void {
    read_buffer.clearAndFree();
    read_used = 0;
}

/// Called for read operations (operator ,)
pub fn operatorRead() u8 {
    // Read an entire line at once if we are out of buffered inputs
    if (read_used >= read_buffer.items.len) {
        if (read_prompt) {
            // Different color than source code prompts.
            std.debug.print("\x1b[32;1m>\x1b[0m ", .{});
            last_printed = ' ';
        }
        read_used = 0;
        read_buffer.clearAndFree();
        while (true) {
            const c = std.io.getStdIn().reader().readByte() catch {
                // In TTY mode, EOF does NOT mean that stdin was closed and
                // the user will be prompted again on the next read operation.
                if (isTTY)
                    return read_eof_char;
                // For pipes, EOF means that stdin was closed. We signal it
                // to the user application but if it reads again, exit as most
                // applications will just enter an infinite loop at this point.
                if (signaled_eof) {
                    printWarning("Reached EOF. No more input available.");
                    std.process.exit(1);
                } else {
                    signaled_eof = true;
                }
                return read_eof_char;
            };
            read_buffer.append(c) catch { return read_eof_char; };
            if (c == '\n')
                break;
        }
    }
    const c = read_buffer.items[read_used];
    read_used += 1;
    
    // With pipe inputs are not visible - echo to make them visible.
    if (! isTTY) {
        var buf: [64]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "\x1b[32;1m{c}\x1b[0m", .{ c }) catch { return c; };
        _ = std.io.getStdOut().writer().write(out) catch 0;
        last_printed = c;
    }
    return c;
}

/// Called for print operations (operator .)
/// Print colored hex code to indicate c is not printable.
pub fn operatorPrint(c: u8) void {
    if (print_binary or isPrintable(c)) {
        std.io.getStdOut().writer().writeByte(c) catch {};
    } else {
        var buf: [64]u8 = undefined;
        const optional_sp = if (last_printed == null or isPrintable(last_printed.?)) "" else " ";
        const out = std.fmt.bufPrint(&buf, "\x1b[31;1m{s}{x:0>2}\x1b[0m", .{ optional_sp, c }) catch { return; };
        _ = std.io.getStdOut().writer().write(out) catch 0;
    }
    last_printed = c;
}

/// Finish current line so that the user application
/// does not mess up our outputs.
pub fn endLine() void {
    if (last_printed) |c| {
        if (c != '\n') {
            std.debug.print("\n", .{});
        }
    }
    last_printed = null;
}

/// Print bold red text
pub fn printWarning(message: []const u8) void {
    endLine();
    std.debug.print("\x1b[31;1m{s}\x1b[0m\n", .{ message });
}

/// Printable ASCII character?
fn isPrintable(c: u8) bool {
    return (c >= 0x20 and c <= 0x7e or c == '\r' or c == '\n' or c == '\t');
}
