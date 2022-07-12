# Z-HTML

This is a work in progress, spec compliant, HTML parser built with [Zig](https://ziglang.org).

## Roadmap

- [x] Tokenizer (missing a few edge cases)
- [ ] Parser (in progress)
- [ ] JavaScript DOM API support

## Tokenizer

The `Tokenizer` struct provides a (mostly) fully featured HTML tokenizer built according to the [WHATGW HTML Spec](https://html.spec.whatwg.org/multipage/parsing.html#tokenization). It is a streaming tokenizer which takes as input a full document, processes the document character by character, and emits both `Token`s and `ParseError`s. An example usage of it by itself could look like this:

```zig
const std = @import("std");
const Tokenizer = @import("zhtml/tokenizer.zig").Tokenizer;

pub fn main() void {
    var allocator = std.heap.page_allocator;
    var tokenizer = try Tokenizer.initWithFile(alloc, "./test.html");
    while (true) {
        var token = self.tokenizer.nextToken() catch |err| {
            std.debug.warn("{} (line: {}, column: {})\n", .{ err, tokenizer.line, tokenizer.column });
            continue;
        };

        if (token) |tok| {
            switch (tok) {
                Token.EndOfFile => break,
                else => std.debug.warn("{}\n", .{ tok });
            }
        }
    }
}
```

though the `Tokenizer` is meant to be used in conjunction with the `Parser`.

## Parser

Work in progress. Check back later.

## License

Copyright 2020 Chris Watson

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
