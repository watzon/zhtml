const std = @import("std");
const testing = std.testing;
const Token = @import("zhtml/token").Token;
const Tokenizer = @import("zhtml/tokenizer").Tokenizer;
const ParseError = @import("zhtml/parse_error").ParseError;

// FIXME: This whole file is rather sloppy with memory
// TODO: Preprocessing the input stream (spec 12.2.3.5)
// TODO: test.doubleEscaped
// TODO: test.lastStartTag
// TODO: If test.doubleEscaped is present and true, then every string within test.output must
//       be further unescaped (as described above) before comparing with the tokenizer's output.
// TODO: Run more .test files once the relevant above TODOs are addressed and the tokenizer progresses

const ignored_tests = [_][]const u8{
    "Unfinished entity",
    "Unfinished numeric entity",
    "Entity with trailing semicolon (1)",
    "Entity with trailing semicolon (2)",
    "Entity without trailing semicolon (1)",
    "Entity without trailing semicolon (2)",
    "Partial entity match at end of file",
    "Non-ASCII character reference name",
    "Entity + newline",
    ";\\uDBC0\\uDC00",
    "Empty hex numeric entities",
    "Invalid digit in hex numeric entity",
    "Empty decimal numeric entities",
    "Invalid digit in decimal numeric entity",
    "Ampersand, number sign",
    "<!----!CR>",
    "<!----!CRLF>",
    "<!DOCTYPE\\u000D",
    "<!DOCTYPE \\u000D",
    "<!DOCTYPE a\\u000D",
    "<!DOCTYPE a PUBLIC\\u000D",
    "<!DOCTYPE a PUBLIC\\u001F",
    "<!DOCTYPE a PUBLIC''\\u000D",
    "<!DOCTYPE a SYSTEM\\u000D",
    "<!DOCTYPE a SYSTEM''\\u000D",
    "<!DOCTYPEa\\u000D",
    "<!DOCTYPEa PUBLIC\\u000D",
    "<!DOCTYPEa PUBLIC''\\u000D",
    "<!DOCTYPEa SYSTEM\\u000D",
    "<!DOCTYPEa SYSTEM''\\u000D",
    "<a\\u000D>",
    "<a \\u000D>",
    "<a a\\u000D>",
    "<a a \\u000D>",
    "<a a=\\u000D>",
    "<a a=''\\u000D>",
    "<a a=a\\u000D>",
    "<\\uDBC0\\uDC00",
    "\\uDBC0\\uDC00",
    "CR followed by non-LF",
    "CR at EOF",
    "CR LF",
    "CR CR",
    "LF CR",
    "text CR CR CR text",
};

test "test1.test" {
    try runTestFile("test/html5lib-tests/tokenizer/test1.test");
}

test "test2.test" {
    try runTestFile("test/html5lib-tests/tokenizer/test2.test");
}

test "test3.test" {
    try runTestFile("test/html5lib-tests/tokenizer/test3.test");
}

test "test4.test" {
    try runTestFile("test/html5lib-tests/tokenizer/test4.test");
}

fn runTestFile(file_path: []const u8) !void {
    var allocator = std.heap.page_allocator;
    var contents = try std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize));
    defer allocator.free(contents);
    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();
    var tree = try parser.parse(contents);
    defer tree.deinit();

    var tests = tree.root.Object.get("tests").?.Array;
    outer: for (tests.items) |test_obj, i| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var arena_allocator = arena.allocator();
        defer arena.deinit();

        const description = test_obj.Object.get("description").?.String;
        for (ignored_tests) |ignored_test| {
            if (std.mem.eql(u8, description, ignored_test)) {
                std.log.warn("Ignoring test '{s}'\n", .{description});
                continue :outer;
            }
        }

        const input = test_obj.Object.get("input").?.String;
        std.debug.print("\n===================\n{}: {s}\n", .{ i, description });
        std.debug.print("\n{s}\n", .{input});
        const expected_tokens = try parseOutput(&arena_allocator, test_obj.Object.get("output").?.Array);
        defer expected_tokens.deinit();

        const expected_errors = blk: {
            if (test_obj.Object.get("errors")) |errors| {
                break :blk try parseErrors(&arena_allocator, errors.Array);
            } else {
                break :blk std.ArrayList(ErrorInfo).init(arena_allocator);
            }
        };
        defer expected_errors.deinit();

        if (expected_errors.items.len > 0) {
            std.debug.print("\nexpected errors:\n", .{});
            for (expected_errors.items) |expected_error| {
                std.debug.print("  {}\n", .{expected_error});
            }
        }
        std.debug.print("===================\n", .{});

        if (test_obj.Object.get("initialStates")) |initial_states_obj| {
            const initial_states = initial_states_obj.Array;
            for (initial_states.items) |initial_state_val| {
                std.debug.print("------------------\nwith initial state: {s}\n------------------\n", .{initial_state_val.String});
                try runTest(&arena_allocator, input, expected_tokens.items, expected_errors.items, parseInitialState(initial_state_val.String).?);
            }
        } else {
            try runTest(&arena_allocator, input, expected_tokens.items, expected_errors.items, null);
        }
    }
}

fn runTest(allocator: *std.mem.Allocator, input: []const u8, expected_tokens: []Token, expected_errors: []ErrorInfo, initial_state: ?Tokenizer.State) !void {
    var tokenizer = try Tokenizer.initWithString(allocator, input);
    if (initial_state) |_initial_state| {
        tokenizer.state = _initial_state;
    }
    var num_tokens: usize = 0;
    var num_errors: usize = 0;
    while (true) {
        var token = tokenizer.nextToken() catch |err| {
            std.log.err("{} at line: {}, column: {}\n", .{ err, tokenizer.line, tokenizer.column });
            try testing.expect(expected_errors.len > 0);
            var error_found = false;
            const id = ErrorInfo.errorToSpecId(err);
            for (expected_errors) |expected_error| {
                // TODO: Compare line number and column number; the html5lib tests don't seem to be consistent
                //       with their expected line/col for errors, so this is disabled for now.
                if (std.mem.eql(u8, expected_error.id, id)) {
                    error_found = true;
                    break;
                }
            }
            try testing.expect(error_found);
            num_errors += 1;
            continue;
        };

        if (token == Token.EndOfFile)
            break;

        const expected_token = expected_tokens[num_tokens];
        std.debug.print("expected: {}\nactual:   {}\n\n", .{ expected_token, token });
        try expectEqualTokens(expected_token, token);
        num_tokens += 1;
    }
    try testing.expectEqual(expected_tokens.len, num_tokens);
    try testing.expectEqual(expected_errors.len, num_errors);
}

fn parseOutput(allocator: *std.mem.Allocator, outputs: anytype) !std.ArrayList(Token) {
    var tokens = try std.ArrayList(Token).initCapacity(allocator.*, outputs.items.len);
    for (outputs.items) |output_obj| {
        const output_array = output_obj.Array.items;
        const token_type_str = output_array[0].String;

        if (std.mem.eql(u8, token_type_str, "DOCTYPE")) {
            // ["DOCTYPE", name, public_id, system_id, correctness]
            try tokens.append(Token{
                .DOCTYPE = .{
                    .name = if (output_array[1] == .Null) null else output_array[1].String,
                    // public_id and system_id are either strings or null.
                    .publicIdentifier = if (output_array[2] == .Null) null else output_array[2].String,
                    .systemIdentifier = if (output_array[3] == .Null) null else output_array[3].String,
                    // correctness is either true or false; true corresponds to the force-quirks flag being false, and vice-versa.
                    .forceQuirks = !output_array[4].Bool,
                },
            });
        } else if (std.mem.eql(u8, token_type_str, "StartTag")) {
            // ["StartTag", name, {attributes}*, true*]
            // ["StartTag", name, {attributes}]
            const attributes_obj = output_array[2].Object;
            var it = attributes_obj.iterator();
            var token = Token{
                .StartTag = .{
                    .name = output_array[1].String,
                    // When the self-closing flag is set, the StartTag array has true as its fourth entry.
                    // When the flag is not set, the array has only three entries for backwards compatibility.
                    .selfClosing = if (output_array.len == 3) false else output_array[3].Bool,
                    .attributes = std.StringHashMap([]const u8).init(allocator.*),
                },
            };
            while (it.next()) |attribute_entry| {
                try token.StartTag.attributes.put(attribute_entry.key_ptr.*, attribute_entry.value_ptr.*.String);
            }
            try tokens.append(token);
        } else if (std.mem.eql(u8, token_type_str, "EndTag")) {
            // ["EndTag", name]
            try tokens.append(Token{
                .EndTag = .{
                    .name = output_array[1].String,
                    .attributes = std.StringHashMap([]const u8).init(allocator.*),
                },
            });
        } else if (std.mem.eql(u8, token_type_str, "Comment")) {
            // ["Comment", data]
            try tokens.append(Token{
                .Comment = .{ .data = output_array[1].String },
            });
        } else if (std.mem.eql(u8, token_type_str, "Character")) {
            // ["Character", data]
            // All adjacent character tokens are coalesced into a single ["Character", data] token.
            var chars_utf8 = try std.unicode.Utf8View.init(output_array[1].String);
            var chars_iterator = chars_utf8.iterator();
            while (chars_iterator.nextCodepoint()) |codepoint| {
                try tokens.append(Token{
                    .Character = .{ .data = codepoint },
                });
            }
        }
    }
    return tokens;
}

pub fn parseErrors(allocator: *std.mem.Allocator, errors: anytype) !std.ArrayList(ErrorInfo) {
    var error_infos = try std.ArrayList(ErrorInfo).initCapacity(allocator.*, errors.items.len);
    for (errors.items) |error_obj| {
        const code = error_obj.Object.get("code").?.String;
        // skip these for now
        // TODO: Errors from preprocessing the input stream
        if (std.mem.eql(u8, code, "control-character-in-input-stream")
            or std.mem.eql(u8, code, "noncharacter-in-input-stream")) {
            continue;
        }
        const line = @intCast(usize, error_obj.Object.get("line").?.Integer);
        const col = @intCast(usize, error_obj.Object.get("col").?.Integer);
        error_infos.appendAssumeCapacity(ErrorInfo{
            .id = code,
            .line = line,
            .column = col,
        });
    }
    return error_infos;
}

fn parseInitialState(str: []const u8) ?Tokenizer.State {
    const map = std.ComptimeStringMap(Tokenizer.State, .{
        .{ "Data state", Tokenizer.State.Data },
        .{ "PLAINTEXT state", Tokenizer.State.PLAINTEXT },
        .{ "RCDATA state", Tokenizer.State.RCDATA },
        .{ "RAWTEXT state", Tokenizer.State.RAWTEXT },
        .{ "Script data state", Tokenizer.State.ScriptData },
        .{ "CDATA section state", Tokenizer.State.CDATASection },
    });
    return map.get(str);
}

fn expectEqualAttributes(expected: std.StringHashMap([]const u8), actual: std.StringHashMap([]const u8)) !void {
    var it = expected.iterator();
    try testing.expectEqual(expected.count(), actual.count());
    while (it.next()) |expected_entry| {
        const actual_value = actual.get(expected_entry.key_ptr.*);
        try testing.expect(actual_value != null);
        try testing.expectEqualSlices(u8, expected_entry.value_ptr.*, actual_value.?);
    }
}

fn expectEqualNullableSlices(comptime T: anytype, expected: ?[]const T, actual: ?[]const T) !void {
    if (expected) |_| {
        try testing.expectEqualSlices(T, expected.?, actual.?);
    } else {
        try testing.expectEqual(expected, actual);
    }
}

fn expectEqualTokens(expected: Token, actual: Token) !void {
    const TokenTag = std.meta.Tag(Token);
    try testing.expect(@as(TokenTag, actual) == @as(TokenTag, expected));
    switch (expected) {
        .DOCTYPE => {
            try expectEqualNullableSlices(u8, expected.DOCTYPE.name, actual.DOCTYPE.name);
            try expectEqualNullableSlices(u8, expected.DOCTYPE.publicIdentifier, actual.DOCTYPE.publicIdentifier);
            try expectEqualNullableSlices(u8, expected.DOCTYPE.systemIdentifier, actual.DOCTYPE.systemIdentifier);
            try testing.expectEqual(expected.DOCTYPE.forceQuirks, actual.DOCTYPE.forceQuirks);
        },
        .StartTag => {
            try expectEqualNullableSlices(u8, expected.StartTag.name, actual.StartTag.name);
            try testing.expectEqual(expected.StartTag.selfClosing, actual.StartTag.selfClosing);
            try expectEqualAttributes(expected.StartTag.attributes, actual.StartTag.attributes);
        },
        .EndTag => {
            try expectEqualNullableSlices(u8, expected.EndTag.name, actual.EndTag.name);
            // Don't compare selfClosing or attributes. From the spec:
            // An end tag that has a / right before the closing > is treated as a regular end tag.
            // Attributes in end tags are completely ignored and do not make their way into the DOM.
        },
        .Comment => {
            try expectEqualNullableSlices(u8, expected.Comment.data, actual.Comment.data);
        },
        .Character => {
            try testing.expectEqual(expected.Character.data, actual.Character.data);
        },
        .EndOfFile => unreachable,
    }
}

const ErrorInfo = struct {
    id: []const u8,
    line: usize,
    column: usize,

    pub fn errorToSpecId(err: ParseError) []const u8 {
        // there might be a cleverer way to do this but oh well
        return switch (err) {
            ParseError.Default => unreachable,
            ParseError.AbruptClosingOfEmptyComment => "abrupt-closing-of-empty-comment",
            ParseError.AbruptDoctypePublicIdentifier => "abrupt-doctype-public-identifier",
            ParseError.AbruptDoctypeSystemIdentifier => "abrupt-doctype-system-identifier",
            ParseError.AbsenceOfDigitsInNumericCharacterReference => "absence-of-digits-in-numeric-character-reference",
            ParseError.CDATAInHtmlContent => "cdata-in-html-content",
            ParseError.CharacterReferenceOutsideUnicodeRange => "character-reference-outside-unicode-range",
            ParseError.ControlCharacterInInputStream => "control-character-in-input-stream",
            ParseError.ControlCharacterReference => "control-character-reference",
            ParseError.EndTagWithAttributes => "end-tag-with-attributes",
            ParseError.DuplicateAttribute => "duplicate-attribute",
            ParseError.EndTagWithTrailingSolidus => "end-tag-with-trailing-solidus",
            ParseError.EofBeforeTagName => "eof-before-tag-name",
            ParseError.EofInCDATA => "eof-in-cdata",
            ParseError.EofInComment => "eof-in-comment",
            ParseError.EofInDOCTYPE => "eof-in-doctype",
            ParseError.EofInScriptHTMLCommentLikeText => "eof-in-script-html-comment-like-text",
            ParseError.EofInTag => "eof-in-tag",
            ParseError.IncorrectlyClosedComment => "incorrectly-closed-comment",
            ParseError.IncorrectlyOpenedComment => "incorrectly-opened-comment",
            ParseError.InvalidCharacterSequenceAfterDoctypeName => "invalid-character-sequence-after-doctype-name",
            ParseError.InvalidFirstCharacterOfTagName => "invalid-first-character-of-tag-name",
            ParseError.MissingAttributeValue => "missing-attribute-value",
            ParseError.MissingDoctypeName => "missing-doctype-name",
            ParseError.MissingDoctypePublicIdentifier => "missing-doctype-public-identifier",
            ParseError.MissingDoctypeSystemIdentifier => "missing-doctype-system-identifier",
            ParseError.MissingEndTagName => "missing-end-tag-name",
            ParseError.MissingQuoteBeforeDoctypePublicIdentifier => "missing-quote-before-doctype-public-identifier",
            ParseError.MissingQuoteBeforeDoctypeSystemIdentifier => "missing-quote-before-doctype-system-identifier",
            ParseError.MissingSemicolonAfterCharacterReference => "missing-semicolon-after-character-reference",
            ParseError.MissingWhitespaceAfterDoctypePublicKeyword => "missing-whitespace-after-doctype-public-keyword",
            ParseError.MissingWhitespaceAfterDoctypeSystemKeyword => "missing-whitespace-after-doctype-system-keyword",
            ParseError.MissingWhitespaceBeforeDoctypeName => "missing-whitespace-before-doctype-name",
            ParseError.MissingWhitespaceBetweenAttributes => "missing-whitespace-between-attributes",
            ParseError.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers => "missing-whitespace-between-doctype-public-and-system-identifiers",
            ParseError.NestedComment => "nested-comment",
            ParseError.NoncharacterCharacterReference => "noncharacter-character-reference",
            ParseError.NoncharacterInInputStream => "noncharacter-in-input-stream",
            ParseError.NonVoidHTMLElementStartTagWithTrailingSolidus => "non-void-html-element-start-tag-with-trailing-solidus",
            ParseError.NullCharacterReference => "null-character-reference",
            ParseError.SurrogateCharacterReference => "surrogate-character-reference",
            ParseError.SurrogateInInputStream => "surrogate-in-input-stream",
            ParseError.UnexpectedCharacterAfterDoctypeSystemIdentifier => "unexpected-character-after-doctype-system-identifier",
            ParseError.UnexpectedCharacterInAttributeName => "unexpected-character-in-attribute-name",
            ParseError.UnexpectedCharacterInUnquotedAttributeValue => "unexpected-character-in-unquoted-attribute-value",
            ParseError.UnexpectedEqualsSignBeforeAttributeName => "unexpected-equals-sign-before-attribute-name",
            ParseError.UnexpectedNullCharacter => "unexpected-null-character",
            ParseError.UnexpectedQuestionMarkInsteadOfTagName => "unexpected-question-mark-instead-of-tag-name",
            ParseError.UnexpectedSolidusInTag => "unexpected-solidus-in-tag",
            ParseError.UnknownNamedCharacterReference => "unknown-named-character-reference",
        };
    }
};

test "ErrorInfo.errorToSpecId" {
    try testing.expectEqualSlices(u8, "eof-in-doctype", ErrorInfo.errorToSpecId(ParseError.EofInDOCTYPE));
}
