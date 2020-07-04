const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

const html =
    \\ <!DOCTYPE html>
    \\ <html>
    \\     <head>
    \\         <!-- A \0 sample comment -->
    \\         <title>This is a foobar page</title>
    \\     </head>
    \\     <body>
    \\         <p private=true>Foo<br />bar</p>
    \\     </body>
    \\ <html>
;

pub fn main() !void { 
    var alloc = std.heap.page_allocator;
    var tok = try Tokenizer.initWithString(alloc, html);
    while (!tok.eof()) {
        std.debug.warn("{}\n", .{ tok.next() });
    }
    for (tok.errors.items) |err| {
        std.debug.warn("{}\n", .{ err });
    }
}