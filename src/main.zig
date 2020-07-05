const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub const log_level: std.log.Level = .debug;

pub fn main() !void { 
    var alloc = std.heap.page_allocator;
    var tokenizer = try Tokenizer.initWithFile(alloc, "./test.html");
    while (true) {
        var token = tokenizer.next() catch |err| {
            std.log.err(.main, "{} at line: {}, column: {}\n", .{ err, tokenizer.line, tokenizer.column });
            continue;
        };

        if (token) |tok| {
            std.log.info(.main, "{}\n", .{ tok });
            if (tok == .EndOfFile) break;
        }
    }
}