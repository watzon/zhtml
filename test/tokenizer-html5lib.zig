const std = @import("std");
const testing = std.testing;
const Token = @import("zhtml/token").Token;
const Tokenizer = @import("zhtml/tokenizer").Tokenizer;
const ParseError = @import("zhtml/parse_error").ParseError;

//! Test runner for the html5lib-tests tokenizer tests
//! https://github.com/html5lib/html5lib-tests/tree/master/tokenizer
//!
//! Expects to be run via `zig build test-html5lib`

// FIXME: This whole file is rather sloppy with memory
// TODO: Preprocessing the input stream (spec 12.2.3.5)
// TODO: test.doubleEscaped
// TODO: test.lastStartTag
// TODO: If test.doubleEscaped is present and true, then every string within test.output must
//       be further unescaped (as described above) before comparing with the tokenizer's output.
// TODO: Run more .test files once the relevant above TODOs are addressed and the tokenizer progresses

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
    for (tests.items) |test_obj, i| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const description = test_obj.Object.get("description").?.String;
        const input = test_obj.Object.get("input").?.String;
        std.debug.print("\n===================\n{}: {}\n", .{ i, description });
        std.debug.print("\n{}\n", .{input});
        const expected_tokens = try parseOutput(&arena.allocator, test_obj.Object.get("output").?.Array);
        defer expected_tokens.deinit();

        const expected_errors = blk: {
            if (test_obj.Object.get("errors")) |errors_obj| {
                break :blk try parseErrors(&arena.allocator, test_obj.Object.get("errors").?.Array);
            } else {
                break :blk std.ArrayList(ErrorInfo).init(&arena.allocator);
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
            const initial_states = test_obj.Object.get("initialStates").?.Array;
            for (initial_states.items) |initial_state_val| {
                std.debug.print("------------------\nwith initial state: {}\n------------------\n", .{initial_state_val.String});
                try runTest(&arena.allocator, input, expected_tokens.items, expected_errors.items, parseInitialState(initial_state_val.String).?);
            }
        } else {
            try runTest(&arena.allocator, input, expected_tokens.items, expected_errors.items, null);
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
            std.log.err(.main, "{} at line: {}, column: {}\n", .{ err, tokenizer.line, tokenizer.column });
            if (expected_errors.len == 0) {
                unreachable;
            }
            var error_found = false;
            const id = ErrorInfo.errorToSpecId(err);
            for (expected_errors) |expected_error| {
                if (std.mem.eql(u8, expected_error.id, id) and expected_error.line == tokenizer.line and expected_error.column == tokenizer.column) {
                    error_found = true;
                    break;
                }
            }
            testing.expect(error_found);
            num_errors += 1;
            continue;
        };

        if (token == Token.EndOfFile)
            break;

        const expected_token = expected_tokens[num_tokens];
        std.debug.print("expected: {}\nactual:   {}\n\n", .{ expected_token, token });
        expectEqualTokens(expected_token, token);
        num_tokens += 1;
    }
    testing.expectEqual(expected_tokens.len, num_tokens);
    testing.expectEqual(expected_errors.len, num_errors);
}

fn parseOutput(allocator: *std.mem.Allocator, outputs: var) !std.ArrayList(Token) {
    var tokens = try std.ArrayList(Token).initCapacity(allocator, outputs.items.len);
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
            var token = Token{
                .StartTag = .{
                    .name = output_array[1].String,
                    // When the self-closing flag is set, the StartTag array has true as its fourth entry.
                    // When the flag is not set, the array has only three entries for backwards compatibility.
                    .selfClosing = if (output_array.len == 3) false else output_array[3].Bool,
                    .attributes = std.StringHashMap([]const u8).init(allocator),
                },
            };
            for (attributes_obj.items()) |attribute_entry| {
                try token.StartTag.attributes.put(attribute_entry.key, attribute_entry.value.String);
            }
            try tokens.append(token);
        } else if (std.mem.eql(u8, token_type_str, "EndTag")) {
            // ["EndTag", name]
            try tokens.append(Token{
                .EndTag = .{
                    .name = output_array[1].String,
                    .attributes = std.StringHashMap([]const u8).init(allocator),
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

pub fn parseErrors(allocator: *std.mem.Allocator, errors: var) !std.ArrayList(ErrorInfo) {
    var error_infos = try std.ArrayList(ErrorInfo).initCapacity(allocator, errors.items.len);
    for (errors.items) |error_obj| {
        const code = error_obj.Object.get("code").?.String;
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

fn expectEqualAttributes(expected: std.StringHashMap([]const u8), actual: std.StringHashMap([]const u8)) void {
    testing.expectEqual(expected.items().len, actual.items().len);
    for (expected.items()) |expected_entry| {
        const actual_value = actual.get(expected_entry.key);
        testing.expect(actual_value != null);
        testing.expectEqualSlices(u8, expected_entry.value, actual_value.?);
    }
}

fn expectEqualNullableSlices(comptime T: type, expected: ?[]const T, actual: ?[]const T) void {
    if (expected) |_| {
        testing.expectEqualSlices(T, expected.?, actual.?);
    } else {
        testing.expectEqual(expected, actual);
    }
}

fn expectEqualTokens(expected: Token, actual: Token) void {
    const TokenTag = @TagType(Token);
    testing.expect(@as(TokenTag, actual) == @as(TokenTag, expected));
    switch (expected) {
        .DOCTYPE => {
            expectEqualNullableSlices(u8, expected.DOCTYPE.name, actual.DOCTYPE.name);
            expectEqualNullableSlices(u8, expected.DOCTYPE.publicIdentifier, actual.DOCTYPE.publicIdentifier);
            expectEqualNullableSlices(u8, expected.DOCTYPE.systemIdentifier, actual.DOCTYPE.systemIdentifier);
            testing.expectEqual(expected.DOCTYPE.forceQuirks, actual.DOCTYPE.forceQuirks);
        },
        .StartTag => {
            expectEqualNullableSlices(u8, expected.StartTag.name, actual.StartTag.name);
            testing.expectEqual(expected.StartTag.selfClosing, actual.StartTag.selfClosing);
            expectEqualAttributes(expected.StartTag.attributes, actual.StartTag.attributes);
        },
        .EndTag => {
            expectEqualNullableSlices(u8, expected.EndTag.name, actual.EndTag.name);
            testing.expectEqual(expected.EndTag.selfClosing, actual.EndTag.selfClosing);
        },
        .Comment => {
            expectEqualNullableSlices(u8, expected.Comment.data, actual.Comment.data);
        },
        .Character => {
            testing.expectEqual(expected.Character.data, actual.Character.data);
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
    testing.expectEqualSlices(u8, "eof-in-doctype", ErrorInfo.errorToSpecId(ParseError.EofInDOCTYPE));
}
