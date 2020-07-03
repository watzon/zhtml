const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

const html =
    \\ <!DOCTYPE html>
    \\ <html>
    \\     <head>
    \\         <!-- A sample comment -->
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
    tok.tokenize();
    for (tok.tokens.items) |token| {
        std.debug.warn("{}\n", .{ token });
    }
}