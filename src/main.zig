const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

pub const log_level: std.log.Level = .debug;

pub fn main() !void { 
    var alloc = std.heap.page_allocator;
    var tok = try Tokenizer.initWithFile(alloc, "./test.html");
    while (!tok.eof()) {
        std.log.debug(.main, "{}\n", .{ tok.next() });
    }

    std.log.debug(.main, "\n", .{});
    
    for (tok.errors.items) |err| {
        std.log.debug(.main, "{}\n", .{ err });
    }
}