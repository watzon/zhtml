const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

fn isQuote(c: u8) bool {
    return c == '"' or c == '\'';
}

fn isWhitespace(c: u8) bool {
    return c == '\n' or c == '\t' or c == ' ' or c == '\r';
}

pub const ParseError = enum {
    UnexpectedNullCharacter,
    UnexpectedQuestionMarkInsteadOfTagName,
    InvalidFirstCharacterOfTagName,
    MissingEndTagName,
    MissingWhitespaceBeforeDoctypeName,
    MissingDoctypeName,
    UnexpectedEqualsSignBeforeAttributeName,
    UnexpectedCharacterInAttributeName,
    MissingAttributeValue,
    UnexpectedCharacterInUnquotedAttributeValue,
    MissingWhitespaceBetweenAttributes,
    UnexpectedSolidusInTag,
    AbruptClosingOfEmptyComment,
    NestedComment,
    IncorrectlyOpenedComment,
    IncorrectlyClosedComment,
    InvalidCharacterSequenceAfterDoctypeName,
};

pub const Attribute = struct {
    name:  []const u8,
    value: []const u8,
};

/// Represents a token to be emitted by the {{Tokenizer}}.
pub const Token = struct {
    kind: Type,
    name: ?[]const u8 = null,
    data: ?[]const u8 = null,
    publicIdent: ?[]const u8 = null,
    systemIdent: ?[]const u8 = null,
    forceQuirks: bool = false,
    selfClosing: bool = false,
    attributes: ?ArrayList(Attribute) = null,

    pub fn initStartTag(allocator: *mem.Allocator) Token {
        return Token{
            .kind = .StartTag,
            .attributes = ArrayList(Attribute).init(allocator),
        };
    }

    pub fn initEndTag(allocator: *mem.Allocator) Token {
        return Token{
            .kind = .EndTag,
            .attributes = ArrayList(Attribute).init(allocator),
        };
    }

    pub const Type = enum {
        DOCTYPE,
        StartTag,
        EndTag,
        Comment,
        Character,
        EndOfFile,      
    };
};

/// Represents the state of the HTML tokenizer as described
/// [here](https://html.spec.whatwg.org/multipage/parsing.html#tokenization)
pub const Tokenizer = struct {
    /// The current state of the parser.
    pub const State = enum {
        Data,
        RCDATA,
        RAWTEXT,
        ScriptData,
        PLAINTEXT,
        TagOpen,
        EndTagOpen,
        TagName,
        RCDATALessThanSign,
        RCDATAEndTagOpen,
        RCDATAEndTagName,
        RAWTEXTLessThanSign,
        RAWTEXTEndTagOpen,
        RAWTEXTEndTagName,
        ScriptDataLessThanSign,
        ScriptDataEndTagOpen,
        ScriptDataEndTagName,
        ScriptDataEscapeStart,
        ScriptDataEscapeStartDash,
        ScriptDataEscaped,
        ScriptDataEscapedDash,
        ScriptDataEscapedDashDash,
        ScriptDataEscapedLessThanSign,
        ScriptDataEscapedEndTagOpen,
        ScriptDataEscapedEndTagName,
        ScriptDataDoubleEscapeStart,
        ScriptDataDoubleEscaped,
        ScriptDataDoubleEscapedDash,
        ScriptDataDoubleEscapedDashDash,
        ScriptDataDoubleEscapedLessThanSign,
        ScriptDataDoubleEscapeEnd,
        BeforeAttributeName,
        AttributeName,
        AfterAttributeName,
        BeforeAttributeValue,
        AttributeValueDoubleQuoted,
        AttributeValueSingleQuoted,
        AttributeValueUnquoted,
        AfterAttributeValueQuoted,
        SelfClosingStartTag,
        BogusComment,
        MarkupDeclarationOpen,
        CommentStart,
        CommentStartDash,
        Comment,
        CommentLessThanSign,
        CommentLessThanSignBang,
        CommentLessThanSignBangDash,
        CommentLessThanSignBangDashDash,
        CommentEndDash,
        CommentEnd,
        CommentEndBang,
        DOCTYPE,
        BeforeDOCTYPEName,
        DOCTYPEName,
        AfterDOCTYPEName,
        AfterDOCTYPEPublicKeyword,
        BeforeDOCTYPEPublicIdentifier,
        DOCTYPEPublicIdentifierDoubleQuoted,
        DOCTYPEPublicIdentifierSingleQuoted,
        AfterDOCTYPEPublicIdentifier,
        BetweenDOCTYPEPublicAndSystemIdentifiers,
        AfterDOCTYPESystemKeyword,
        BeforeDOCTYPESystemIdentifier,
        DOCTYPESystemIdentifierDoubleQuoted,
        DOCTYPESystemIdentifierSingleQuoted,
        AfterDOCTYPESystemIdentifier,
        BogusDOCTYPE,
        CDATASection,
        CDATASectionBracket,
        CDATASectionEnd,
        CharacterReference,
        NamedCharacterReference,
        AmbiguousAmpersand,
        NumericCharacterReference,
        HexadecimalCharacterReferenceStart,
        DecimalCharacterReferenceStart,
        HexadecimalCharacterReference,
        DecimalCharacterReference,
        NumericCharacterReferenceEnd,
    };

    const Self = @This();
    
    allocator: *mem.Allocator,
    state: State = .Data,
    returnState: ?State = null,
    tokens: ArrayList(Token),
    // denotes if contents have been heap allocated (from a file)
    allocated: bool,
    filename: []const u8,
    contents: []const u8,
    line: usize,
    column: usize,
    index: usize,
    reconsume: bool = false,

    /// Create a new {{Tokenizer}} instance using a file.
    pub fn initWithFile(allocator: *mem.Allocator, filename: []const u8) !Tokenizer {
        var contents = try std.fs.cwd().readFileAlloc(allocator, filename, std.math.maxInt(usize));
        var tokenizer = try Tokenizer.initWithString(allocator, contents);
        tokenizer.filename = filename;
        tokenizer.allocated = true;
        return tokenizer;
    }

    /// Create a new {{Tokenizer}} instance using a string.
    pub fn initWithString(allocator: *mem.Allocator, str: []const u8) !Tokenizer {
        return Tokenizer{
            .allocator = allocator,
            .tokens = ArrayList(Token).init(allocator),
            .allocated = false,
            .filename = "",
            .contents = str,
            .line = 1,
            .column = 0,
            .index = 0,
        };
    }

    pub fn deinit(self: Self) void {
        if (self.allocated) {
            self.allocator.free(self.tokens);
        }
    }

    pub fn tokenize(self: *Self) void {
        var tokenData = ArrayList(u8).init(self.allocator);
        var temporaryBuffer = ArrayList(u8).init(self.allocator);
        var commentData = ArrayList(u8).init(self.allocator);
        var currentAttributeName = ArrayList(u8).init(self.allocator);
        var currentAttributeValue = ArrayList(u8).init(self.allocator);
        var currentToken: ?Token = null;

        while (!self.eof()) {
            std.debug.warn("{}\n", .{self.state});
            switch (self.state) {
                .Data => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '&' => {
                            self.returnState = .Data;
                            self.state = .CharacterReference;
                        },
                        '<' => {
                            self.state = .TagOpen;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.emitNullCharacterToken();
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            self.emitCharacterToken(buffer);
                        }
                    }
                },
                .RCDATA => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '&' => {
                            self.returnState = .RCDATA;
                            self.state = .CharacterReference;
                        },
                        '<' => {
                            self.state = .RCDATALessThanSign;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.emitCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            self.emitCharacterToken(buffer);
                        }
                    }
                },
                .RAWTEXT => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '<' => {
                            self.state = .RAWTEXTLessThanSign;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.emitCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            self.emitCharacterToken(buffer);
                        }
                    }
                },
                .ScriptData => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '<' => {
                            self.state = .ScriptDataLessThanSign;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.emitCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            self.emitCharacterToken(buffer);
                        }
                    }
                },
                .PLAINTEXT => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.emitCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            self.emitCharacterToken(buffer);
                        }
                    }
                },
                .TagOpen => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '!' => {
                            self.state = .MarkupDeclarationOpen;
                        },
                        '/' => {
                            self.state = .EndTagOpen;
                        },
                        '?' => {
                            self.parseError(.UnexpectedQuestionMarkInsteadOfTagName);                            
                            currentToken = Token{ .kind = .Comment };
                            self.state = .BogusComment;
                            self.reconsume = true;
                        },
                        else => {
                            if (std.ascii.isAlpha(next_char)) {
                                currentToken = Token.initStartTag(self.allocator);
                                self.state = .TagName;
                                self.reconsume = true;
                            } else {
                                self.parseError(.InvalidFirstCharacterOfTagName);
                                self.emitCharacterToken("<");
                                self.state = .Data;
                                self.reconsume = true;
                            }
                        }
                    }
                },
                .EndTagOpen => {
                    var next_char = self.nextChar();
                    if (next_char == '>') {
                        self.parseError(.MissingEndTagName);
                        self.state = .Data;
                    } else if (std.ascii.isAlpha(next_char)) {
                        currentToken = Token.initEndTag(self.allocator);
                        self.state = .TagName;
                        self.reconsume = true;
                    } else {
                        self.parseError(.InvalidFirstCharacterOfTagName);
                        currentToken = Token{ .kind = .Comment };
                        self.reconsume = true;
                        self.state = .BogusComment;
                    }
                },
                .TagName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BeforeAttributeName;
                        },
                        '/' => {
                            self.state = .SelfClosingStartTag;
                        },
                        '>' => {
                            var name = tokenData.toOwnedSlice();
                            currentToken.?.name = name;
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.emitCharacterToken("�");
                        },
                        else => {
                            var lowered = std.ascii.toLower(next_char);
                            tokenData.append(lowered) catch unreachable;
                        }
                    }
                },
                .RCDATALessThanSign => {
                    var next_char = self.nextChar();
                    if (next_char == '/') {
                        temporaryBuffer.shrink(0);
                        self.state = .RCDATAEndTagOpen;
                    } else {
                        self.emitCharacterToken("<");
                        self.reconsume = true;
                        self.state = .RCDATA;
                    }
                },
                .RCDATAEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        currentToken = Token.initEndTag(self.allocator);
                    } else {
                        self.emitCharacterToken("<");
                        self.emitCharacterToken("/");
                    }
                    self.reconsume = true;
                    self.state = .RCDATA;
                },
                .RCDATAEndTagName => {
                    // TODO: Requires more state data than is currently available.
                    // https://html.spec.whatwg.org/multipage/parsing.html#rcdata-end-tag-name-state
                    unreachable;
                },
                .BeforeAttributeName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing.
                        },
                        '/', '>' => {
                            self.state = .AfterAttributeName;
                            self.reconsume = true;
                        },
                        '=' => {
                            self.parseError(.UnexpectedEqualsSignBeforeAttributeName);
                            currentAttributeName.shrink(1);
                            currentAttributeName.append(self.currentChar()) catch unreachable;
                            currentAttributeValue.shrink(0);
                            self.state = .AttributeName;
                        },
                        else => {
                            currentAttributeName.shrink(0);
                            currentAttributeValue.shrink(0);
                            self.state = .AttributeName;
                            self.reconsume = true;
                        }
                    }
                },
                .AttributeName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ', '/', '>' => {
                            self.state = .AfterAttributeName;
                            self.reconsume = true;
                        },
                        '=' => {
                            self.state = .BeforeAttributeValue;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            currentAttributeName.appendSlice("�") catch unreachable;
                        },
                        '"', '\'', '<' => {
                            self.parseError(.UnexpectedCharacterInAttributeName);
                            currentAttributeName.append(next_char) catch unreachable;
                        },
                        else => {
                            next_char = std.ascii.toLower(next_char);
                            currentAttributeName.append(next_char) catch unreachable;
                        }
                    }
                },
                .AfterAttributeName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing.
                        },
                        '/' => {
                            self.state = .SelfClosingStartTag;
                        },
                        '=' => {
                            self.state = .BeforeAttributeValue;
                        },
                        '>' => {
                            const attr = Attribute{
                                .name = currentAttributeName.toOwnedSlice(),
                                .value = currentAttributeValue.toOwnedSlice(),
                            };
                            currentToken.?.attributes.?.append(attr) catch unreachable;
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        else => {
                            currentAttributeName.shrink(0);
                            currentAttributeValue.shrink(0);
                            self.state = .AttributeName;
                            self.reconsume = true;
                        }
                    }
                },
                .BeforeAttributeValue => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing.
                        },
                        '"' => {
                            self.state = .AttributeValueDoubleQuoted;
                        },
                        '\'' => {
                            self.state = .AttributeValueSingleQuoted;
                        },
                        '>' => {
                            self.parseError(.MissingAttributeValue);
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .AttributeValueUnquoted;
                        }
                    }
                },
                .AttributeValueDoubleQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '"' => {
                            self.state = .AfterAttributeValueQuoted;
                        },
                        '&' => {
                            self.returnState = .AttributeValueDoubleQuoted;
                            self.state = .CharacterReference;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            currentAttributeValue.appendSlice("�") catch unreachable;
                        },
                        else => {
                            currentAttributeValue.append(next_char) catch unreachable;
                        }
                    }
                },
                .AttributeValueSingleQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\'' => {
                            self.state = .AfterAttributeValueQuoted;
                        },
                        '&' => {
                            self.returnState = .AttributeValueSingleQuoted;
                            self.state = .CharacterReference;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            currentAttributeValue.appendSlice("�") catch unreachable;
                        },
                        else => {
                            currentAttributeValue.append(next_char) catch unreachable;
                        }
                    }
                },
                .AttributeValueUnquoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BeforeAttributeName;
                        },
                        '&' => {
                            self.returnState = .AttributeValueUnquoted;
                            self.state = .CharacterReference;
                        },
                        '>' => {
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        '"', '\'', '<', '=', '`' => {
                            self.parseError(.UnexpectedCharacterInUnquotedAttributeValue);
                            currentAttributeValue.append(next_char) catch unreachable;
                        },
                        else => {
                            currentAttributeValue.append(next_char) catch unreachable;
                        }
                    }
                },
                .AfterAttributeValueQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BeforeAttributeName;
                        },
                        '/' => {
                            self.state = .SelfClosingStartTag;
                        },
                        '>' => {
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        else => {
                            self.state = .BeforeAttributeName;
                            self.reconsume = true;
                        }
                    }
                },
                .SelfClosingStartTag => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '>' => {
                            currentToken.?.selfClosing = true;
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        else => {
                            self.parseError(.UnexpectedSolidusInTag);
                            self.reconsume = true;
                            self.state = .BeforeAttributeName;
                        }
                    }
                },
                .MarkupDeclarationOpen => {
                    var next_seven = self.peekN(7);
                    next_seven = std.ascii.allocLowerString(self.allocator, next_seven) catch unreachable;

                    if (mem.eql(u8, next_seven[0..2], "--")) {
                        self.index += 2;
                        self.state = .CommentStart;
                    } else if (mem.eql(u8, next_seven, "doctype")) {
                        self.index += 7;
                        self.state = .DOCTYPE;
                    } else if (mem.eql(u8, next_seven, "[cdata[")) {
                        // TODO
                        unreachable;
                    } else {
                        self.state = .BogusComment;
                    }
                },
                .CommentStart => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .CommentStartDash;
                        },
                        '>' => {
                            self.parseError(.AbruptClosingOfEmptyComment);
                            self.emitToken(Token{ .kind = .Comment, .data = commentData.toOwnedSlice() });
                            self.state = .Data;  
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .CommentStartDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .CommentEnd;
                        },
                        '>' => {
                            self.parseError(.AbruptClosingOfEmptyComment);
                            self.emitToken(Token{ .kind = .Comment, .data = commentData.toOwnedSlice() });
                            self.state = .Data;  
                        },
                        else => {
                            commentData.append('-') catch unreachable;
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .Comment => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '<' => {
                            commentData.append(next_char) catch unreachable;
                            self.state = .CommentLessThanSign;
                        },
                        '-' => {
                            self.state = .CommentEndDash;  
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            commentData.appendSlice("�") catch unreachable;
                        },
                        else => {
                            commentData.append(next_char) catch unreachable;
                        }
                    }
                },
                .CommentLessThanSign => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '!' => {
                            commentData.append('!') catch unreachable;
                            self.state = .CommentLessThanSignBang;
                        },
                        '<' => {
                            commentData.append(next_char) catch unreachable;
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .CommentLessThanSignBang => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .CommentLessThanSignBangDash;
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .CommentLessThanSignBangDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .CommentLessThanSignBangDashDash;
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .CommentLessThanSignBangDashDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '>' => {
                            self.reconsume = true;
                            self.state = .CommentEnd;
                        },
                        else => {
                            self.parseError(.NestedComment);
                            self.reconsume = true;
                            self.state = .CommentEnd;
                        }
                    }
                },
                .CommentEndDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .CommentEnd;
                        },
                        else => {
                            commentData.append(next_char) catch unreachable;
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .CommentEnd => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '>' => {
                            self.emitToken(Token{ .kind = .Comment, .data = commentData.toOwnedSlice() });
                            self.state = .Data;
                        },
                        '!' => {
                            self.state = .CommentEndBang;
                        },
                        '-' => {
                            commentData.append(next_char) catch unreachable;
                        },
                        else => {
                            commentData.appendSlice("--") catch unreachable;
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .CommentEndBang => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            commentData.appendSlice("--!") catch unreachable;
                            self.state = .CommentEndDash;
                        },
                        '>' => {
                            self.parseError(.IncorrectlyClosedComment);
                            self.emitToken(Token{ .kind = .Comment, .data = commentData.toOwnedSlice() });
                            self.state = .Data;
                        },
                        else => {
                            commentData.appendSlice("--!") catch unreachable;
                            self.reconsume = true;
                            self.state = .Comment;
                        }
                    }
                },
                .DOCTYPE => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BeforeDOCTYPEName;
                        },
                        '>' => {
                            self.reconsume = true;
                        },
                        else => {
                            self.parseError(.MissingWhitespaceBeforeDoctypeName);
                            self.state = .BeforeDOCTYPEName;
                            self.reconsume = true;
                        }
                    }
                },
                .BeforeDOCTYPEName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing.
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            currentToken = Token{ .kind = .DOCTYPE };
                            currentToken.?.name = "�";
                            self.state = .DOCTYPEName;
                        },
                        '>' => {
                            self.parseError(.MissingDoctypeName);
                            currentToken = Token{ .kind = .DOCTYPE };
                            currentToken.?.forceQuirks = true;
                            self.emitToken(currentToken.?);
                            currentToken = null;
                            self.state = .Data;
                        },
                        else => {
                            next_char = std.ascii.toLower(next_char);
                            currentToken = Token{ .kind = .DOCTYPE };
                            tokenData.append(next_char) catch unreachable;
                            self.state = .DOCTYPEName;
                        }
                    }
                },
                .DOCTYPEName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .AfterDOCTYPEName;
                        },
                        '>' => {
                            var name = tokenData.toOwnedSlice();
                            currentToken.?.name = name;
                            self.emitToken(currentToken.?);
                            self.state = .Data;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            currentToken = Token{ .kind = .DOCTYPE };
                            tokenData.appendSlice("�") catch unreachable;
                        },
                        else => {
                            next_char = std.ascii.toLower(next_char);
                            currentToken = Token{ .kind = .DOCTYPE };
                            tokenData.append(next_char) catch unreachable;
                        }
                    }
                },
                .AfterDOCTYPEName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing.
                        },
                        '>' => {
                            self.emitToken(currentToken.?);
                            self.state = .Data;
                        },
                        else => {
                            var next_six = std.ascii.toLower(self.peekN(6));
                            if (mem.eql(next_six, "public")) {
                                self.index += 6;
                                self.state = .AfterDOCTYPEPublicKeyword;
                            } else if (mem.eql(next_six, "system")) {
                                self.index += 6; 
                                self.state = .AfterDOCTYPESystemKeyword;
                            } else {
                                self.parseError(.InvalidCharacterSequenceAfterDoctypeName);
                                currentToken.forceQuirks = true;
                                self.reconsume = true;
                                self.state = .BogusDOCTYPE;
                            }
                        }
                    }
                },
                else => {
                    std.debug.warn("State {} not yet implemented. Char: {}\n", .{ self.state, self.peekChar() });
                    unreachable;
                }
            }
        }

        // We're done tokenizing, so emit the final EOF token.
        self.emitEofToken();
    }

    fn parseError(self: Self, err: ParseError) void {
        // TODO
    }

    fn emitToken(self: *Self, token: Token) void {
        return self.tokens.append(token) catch unreachable;
    }

    fn emitEofToken(self: *Self) void {
        self.emitToken(Token{ .kind = .EndOfFile });
    }

    fn emitCharacterToken(self: *Self, char: []const u8) void {
        const token = Token { .kind = .Character, .data = char };
        self.emitToken(token);
    }

    fn emitNullCharacterToken(self: *Self) void {
        self.emitCharacterToken(&[_]u8{ 0 });
    }

    fn lastToken(self: *Self) ?Token {
        var token_count = self.tokens.items.len;
        if (token_count > 0) {
            return self.tokens.items[token_count - 1];
        } else {
            return null;
        }
    }

    fn nextChar(self: *Self) u8 {
        if (self.reconsume) {
            self.reconsume = false;
            return self.currentChar();
        }

        if (self.index >= self.contents.len) {
            return 0; // EOF
        }

        var c = self.contents[self.index];
        if (c == '\n') {
            self.line += 1;
            self.column = 0;
        }

        self.index += 1;
        self.column += 1;
        return c;
    }

    fn currentChar(self: *Self) u8 {
        if (self.index == 0) {
            return self.contents[self.index];
        } else if (self.index >= self.contents.len) {
            return self.contents[self.contents.len - 1];
        } else {
            return self.contents[self.index - 1];
        }
    }

    fn peekChar(self: *Self) u8 {
        if (self.reconsume) {
            return self.currentChar();
        }

        if (self.index >= self.contents.len) {
            return 0; // EOF
        }

        return self.contents[self.index];
    }

    fn peekN(self: *Self, n: usize) []const u8 {
        // TODO: Error handling
        var index = self.getIndex();
        return self.contents[(index + 1)..(index + n + 1)];
    }

    fn getIndex(self: *Self) usize {
        if (self.index == 0) return 0;
        return self.index - 1;
    }

    fn nextCharIgnoreWhitespace(self: *Self) u8 {
        var c = self.nextChar();
        while (isWhitespace(c)) c = self.nextChar();
        return c;
    }

    fn ignoreWhitespace(self: Self) u8 {
        var c = self.curChar();
        while (isWhitespace(c)) {
            c = self.nextChar();
        }
        return c;
    }

    fn isNewline(self: Self, c: u8) bool {
        var n = c;
        if (n == '\r') {
            n = self.peekChar();
        }
        if (n == '\n') {
            return true;
        }
        return false;
    }

    fn eof(self: Self) bool {
        if (self.index >= self.contents.len) return true;
        return false;
    }
};