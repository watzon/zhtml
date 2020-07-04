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

pub const ParseError = error {
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
    MissingWhitespaceAfterDoctypePublicKeyword,
    MissingDoctypePublicIdentifier,
    MissingQuoteBeforeDoctypePublicIdentifier,
};

pub const Attribute = struct {
    name:  []const u8,
    value: []const u8,
};

/// Represents a token to be emitted by the {{Tokenizer}}.
pub const Token = union(enum) {
    DOCTYPE: struct {
        name: ?[]const u8 = null,
        publicIdentifier: ?[]const u8 = null,
        systemIdentifier: ?[]const u8 = null,
        forceQuirks: bool = false,
    },
    StartTag: struct {
        name: ?[]const u8 = null,
        selfClosing: bool = false,
        attributes: ArrayList(Attribute),
    },
    EndTag: struct {
        name: ?[]const u8 = null,
        selfClosing: bool = false,
        attributes: ArrayList(Attribute),
    },
    Comment: struct {
        data: ?[]const u8 = null,
    },
    Character: struct {
        data: u23,
    },
    EndOfFile,
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
    backlog: ArrayList(Token),
    // denotes if contents have been heap allocated (from a file)
    allocated: bool,
    filename: []const u8,
    contents: []const u8,
    line: usize,
    column: usize,
    index: usize,
    reconsume: bool = false,

    tokenData: ArrayList(u8),
    temporaryBuffer: ArrayList(u8),
    publicIdentifier: ArrayList(u8),
    commentData: ArrayList(u8),
    currentAttributeName: ArrayList(u8),
    currentAttributeValue: ArrayList(u8),
    currentToken: ?Token = null,

    /// Create a new {{Tokenizer}} instance using a file.
    pub fn initWithFile(allocator: *mem.Allocator, filename: []const u8) !Tokenizer {
        var contents = try std.fs.cwd().readFileAlloc(allocator, filename, std.math.maxInt(usize));
        var tokenizer = try Tokenizer.initWithString(allocator, contents);
        tokenizer.backlog = ArrayList(Token).init(allocator);
        tokenizer.filename = filename;
        tokenizer.allocated = true;
        tokenizer.tokenData = ArrayList(u8).init(allocator);
        tokenizer.temporaryBuffer = ArrayList(u8).init(allocator);
        tokenizer.publicIdentifier = ArrayList(u8).init(allocator);
        tokenizer.commentData = ArrayList(u8).init(allocator);
        tokenizer.currentAttributeName = ArrayList(u8).init(allocator);
        tokenizer.currentAttributeValue = ArrayList(u8).init(allocator);
        return tokenizer;
    }

    /// Create a new {{Tokenizer}} instance using a string.
    pub fn initWithString(allocator: *mem.Allocator, str: []const u8) !Tokenizer {
        return Tokenizer{
            .allocator = allocator,
            .allocated = false,
            .backlog = ArrayList(Token).init(allocator),
            .tokenData = ArrayList(u8).init(allocator),
            .temporaryBuffer = ArrayList(u8).init(allocator),
            .publicIdentifier = ArrayList(u8).init(allocator),
            .commentData = ArrayList(u8).init(allocator),
            .currentAttributeName = ArrayList(u8).init(allocator),
            .currentAttributeValue = ArrayList(u8).init(allocator),
            .filename = "",
            .contents = str,
            .line = 1,
            .column = 0,
            .index = 0,
        };
    }

    pub fn deinit(self: Self) void {
        if (self.allocated) {
            self.allocator.free(self.contents);
        }
    }

    pub fn reset(self: *Self) void {
        self.line = 1;
        self.column = 0;
        self.index = 0;
        self.deinit();
    }

    pub fn next(self: *Self) ParseError!?Token {
        // If the token backlog contains items, pop the last one and
        // return it.
        if (self.backlog.items.len > 0) {
            return self.backlog.pop();
        }

        // Check if we're at the EndOfFile. If so, for now, just return an
        // EndOfFile token, but later we'll need to do specific checking inside
        // of the below switch statement.
        if (self.eof()) {
            return Token.EndOfFile;
        }

        switch (self.state) {
            // 12.2.5.1 Data state
            .Data => {
                var next_char = self.nextChar();
                switch (next_char) {
                    // '&' => {
                    //     self.returnState = .Data;
                    //     self.state = .CharacterReference;
                    // },
                    '<' => {
                        self.state = .TagOpen;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = 0x00  } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.2 RCDATA state
            .RCDATA => {
                var next_char = self.nextChar();
                switch (next_char) {
                    // '&' => {
                    //     self.returnState = .RCDATA;
                    //     self.state = .CharacterReference;
                    // },
                    '<' => {
                        self.state = .RCDATALessThanSign;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.3 RAWTEXT state
            .RAWTEXT => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '<' => {
                        self.state = .RAWTEXTLessThanSign;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.4 Script data state
            .ScriptData => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '<' => {
                        self.state = .ScriptDataLessThanSign;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.5 PLAINTEXT state
            .PLAINTEXT => {
                var next_char = self.nextChar();
                switch (next_char) {
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.6 Tag open state
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
                        self.currentToken = Token { .Comment = .{ } };
                        self.state = .BogusComment;
                        self.reconsume = true;
                        return ParseError.UnexpectedQuestionMarkInsteadOfTagName;
                    },
                    else => {
                        if (std.ascii.isAlpha(next_char)) {
                            self.currentToken = Token { .StartTag = .{ .attributes = ArrayList(Attribute).init(self.allocator) } };
                            self.state = .TagName;
                            self.reconsume = true;
                        } else {
                            self.state = .Data;
                            self.reconsume = true;
                            self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                            return ParseError.InvalidFirstCharacterOfTagName;
                        }
                    }
                }
            },
            // 12.2.5.7 End tag open state
            .EndTagOpen => {
                var next_char = self.nextChar();
                if (next_char == '>') {
                    self.state = .Data;
                    return ParseError.MissingEndTagName;
                } else if (std.ascii.isAlpha(next_char)) {
                    self.currentToken = Token { .EndTag = .{ .attributes = ArrayList(Attribute).init(self.allocator) } };
                    self.state = .TagName;
                    self.reconsume = true;
                } else {
                    self.currentToken = Token { .Comment = .{ } };
                    self.reconsume = true;
                    self.state = .BogusComment;
                    return ParseError.InvalidFirstCharacterOfTagName;
                }
            },
            // 12.2.5.8 Tag name state
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
                        var name = self.tokenData.toOwnedSlice();
                        switch (self.currentToken.?) {
                            .StartTag => |*tag| tag.name = name,
                            .EndTag => |*tag| tag.name = name,
                            else => {}
                        }
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        var lowered = std.ascii.toLower(next_char);
                        self.tokenData.append(lowered) catch unreachable;
                    }
                }
            },
            // 12.2.5.9 RCDATA less-than sign state
            .RCDATALessThanSign => {
                var next_char = self.nextChar();
                if (next_char == '/') {
                    self.temporaryBuffer.shrink(0);
                    self.state = .RCDATAEndTagOpen;
                } else {
                    self.reconsume = true;
                    self.state = .RCDATA;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                }
            },
            // 12.2.5.10 RCDATA end tag open state
            .RCDATAEndTagOpen => {
                var next_char = self.nextChar();
                if (std.ascii.isAlpha(next_char)) {
                    self.currentToken = Token{ .EndTag = .{ .attributes = ArrayList(Attribute).init(self.allocator) } };
                } else {
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    self.backlog.append(Token { .Character = .{ .data = '/' } }) catch unreachable;
                }
                self.reconsume = true;
                self.state = .RCDATA;
            },
            // 12.2.5.11 RCDATA end tag name state
            .RCDATAEndTagName => {
                // TODO: Requires more state data than is currently available.
                // https://html.spec.whatwg.org/multipage/parsing.html#rcdata-end-tag-name-state
                unreachable;
            },
            // 12.2.5.12 RAWTEXT less-than sign state
            .RAWTEXTLessThanSign => {
                var next_char = self.nextChar();
                if (next_char == '/') {
                    self.temporaryBuffer.shrink(0);
                    self.state = .RAWTEXT;
                } else {
                    self.reconsume = true;
                    self.state = .RAWTEXT;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                }
            },
            // 12.2.5.13 RAWTEXT end tag open state
            .RAWTEXTEndTagOpen => {
                var next_char = self.nextChar();
                if (std.ascii.isAlpha(next_char)) {
                    self.reconsume = true;
                    self.state = .RAWTEXTEndTagName;
                    self.backlog.append(Token { .EndTag = .{ .attributes = ArrayList(Attribute).init(self.allocator) } } ) catch unreachable;
                } else {
                    self.reconsume = true;
                    self.state = .RAWTEXTEndTagName;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    self.backlog.append(Token { .Character = .{ .data = '/' } }) catch unreachable;
                }
            },
            // 12.2.5.14 RAWTEXT end tag name state
            .RAWTEXTEndTagName => {
                // TODO: Reqiures more state information than we have available right now
                unreachable;
            },
            // 12.2.5.15 Script data less-than sign state
            .ScriptDataLessThanSign => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '/' => {
                        self.temporaryBuffer.shrink(0);
                        self.state = .ScriptDataEndTagOpen;
                    },
                    '!' => {
                        self.state = .ScriptDataEscapeStart;
                        self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                        self.backlog.append(Token { .Character = .{ .data = '!' } }) catch unreachable;
                    },
                    else => {
                        self.reconsume = true;
                        self.state = .ScriptData;
                        self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.16 Script data end tag open state
            .ScriptDataEndTagOpen => {
                var next_char = self.nextChar();
                if (std.ascii.isAlpha(next_char)) {
                    self.currentToken = Token { .EndTag = .{ .attributes = ArrayList(Attribute).init(self.allocator) } };
                    self.reconsume = true;
                    self.state = .ScriptDataEndTagName;
                } else {
                    self.reconsume = true;
                    self.state = .ScriptData;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    self.backlog.append(Token { .Character = .{ .data = '/' } }) catch unreachable;
                }
            },
            // 12.2.5.17 Script data end tag name state
            .ScriptDataEndTagName => {
                unreachable;
            },
            // 12.2.5.18 Script data escape start state
            .ScriptDataEscapeStart => {
                var next_char = self.nextChar();
                if (next_char == '-') {
                    self.state = .ScriptDataEscapeStart;
                    self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                } else {
                    self.reconsume = true;
                    self.state = .ScriptData;
                }
            },
            // 12.2.5.19 Script data escape start dash state
            .ScriptDataEscapeStartDash => {
                var next_char = self.nextChar();
                if (next_char == '-') {
                    self.state = .ScriptDataEscapedDashDash;
                    self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                } else {
                    self.reconsume = true;
                    self.state = .ScriptData;
                }
            },
            // 12.2.5.20 Script data escaped state
            .ScriptDataEscaped => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .ScriptDataEscapedDash;
                        self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                    },
                    '<' => {
                        self.state = .ScriptDataEscapedLessThanSign;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.21 Script data escaped dash state
            .ScriptDataEscapedDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .ScriptDataEscapedDashDash;
                        self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                    },
                    '<' => {
                        self.state = .ScriptDataEscapedLessThanSign;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.state = .ScriptDataEscaped;
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.22 Script data escaped dash dash state
            .ScriptDataEscapedDashDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                    },
                    '<' => {
                        self.state = .ScriptDataEscapedLessThanSign;
                    },
                    0x00 => {
                        self.state = .ScriptDataEscaped;
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.state = .ScriptDataEscaped;
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.23 Script data escaped less-than sign state
            .ScriptDataEscapedLessThanSign => {
                var next_char = self.nextChar();
                if (next_char == '/') {
                    self.temporaryBuffer.shrink(0);
                    self.state = .ScriptDataEscapedEndTagOpen;
                } else if (std.ascii.isAlpha(next_char)) {
                    self.temporaryBuffer.shrink(0);
                    self.reconsume = true;
                    self.state = .ScriptDataDoubleEscapeStart;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                } else {
                    self.reconsume = true;
                    self.state = .ScriptDataEscaped;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                }
            },
            // 12.2.5.24 Script data escaped end tag open state
            .ScriptDataEscapedEndTagOpen => {
                var next_char = self.nextChar();
                if (std.ascii.isAlpha(next_char)) {
                    self.currentToken = Token { .EndTag = .{ .attributes = ArrayList(Attribute).init(self.allocator) } };
                    self.reconsume = true;
                    self.state = .ScriptDataEscapedEndTagName;
                } else {
                    self.reconsume = true;
                    self.state = .ScriptDataEscaped;
                    self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    self.backlog.append(Token { .Character = .{ .data = '/' } }) catch unreachable;
                }
            },
            // 12.2.5.25 Script data escaped end tag name state
            .ScriptDataEscapedEndTagName => {
                unreachable;
            },
            // 12.2.5.26 Script data double escape start state
            .ScriptDataDoubleEscapeStart => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ', '/', '>' => {
                        if (mem.eql(u8, self.temporaryBuffer.items, "script")) {
                            self.state = .ScriptDataDoubleEscaped;
                        } else {
                            self.state = .ScriptDataEscaped;
                        }
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    },
                    else => {
                        if (std.ascii.isAlpha(next_char)) {
                            var lowered = std.ascii.toLower(next_char);
                            self.temporaryBuffer.append(lowered) catch unreachable;
                            self.backlog.append(Token { .Character = .{ .data = lowered } }) catch unreachable;
                        } else {
                            self.reconsume = true;
                            self.state = .ScriptDataEscaped;
                        }
                    }
                }
            },
            // 12.2.5.27 Script data double escaped state
            .ScriptDataDoubleEscaped => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .ScriptDataDoubleEscapedDash;
                        self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                    },
                    '<' => {
                        self.state = .ScriptDataDoubleEscapedLessThanSign;
                        self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    },
                    0x00 => {
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.28 Script data double escaped dash state
            .ScriptDataDoubleEscapedDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .ScriptDataDoubleEscapedDashDash;
                        self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                    },
                    '<' => {
                        self.state = .ScriptDataDoubleEscapedLessThanSign;
                        self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    },
                    0x00 => {
                        self.state = .ScriptDataDoubleEscaped;
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.state = .ScriptDataDoubleEscaped;
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.29 Script data double escaped dash dash state
            .ScriptDataDoubleEscapedDashDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.backlog.append(Token { .Character = .{ .data = '-' } }) catch unreachable;
                    },
                    '<' => {
                        self.state = .ScriptDataDoubleEscapedLessThanSign;
                        self.backlog.append(Token { .Character = .{ .data = '<' } }) catch unreachable;
                    },
                    '>' => {
                        self.state = .ScriptData;
                        self.backlog.append(Token { .Character = .{ .data = '>' } }) catch unreachable;
                    },
                    0x00 => {
                        self.state = .ScriptDataDoubleEscaped;
                        self.backlog.append(Token { .Character = .{ .data = '�' } }) catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.state = .ScriptDataDoubleEscaped;
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    }
                }
            },
            // 12.2.5.30 Script data double escaped less-than sign state
            .ScriptDataDoubleEscapedLessThanSign => {
                var next_char = self.nextChar();
                if (next_char == '/') {
                    self.temporaryBuffer.shrink(0);
                    self.state = .ScriptDataDoubleEscapeEnd;
                    self.backlog.append(Token { .Character = .{ .data = '/' } }) catch unreachable;
                } else {
                    self.reconsume = true;
                    self.state = .ScriptDataDoubleEscaped;
                }
            },
            // 12.2.5.31 Script data double escape end state
            .ScriptDataDoubleEscapeEnd => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ', '/', '>' => {
                        if (mem.eql(u8, self.temporaryBuffer.items, "script")) {
                            self.state = .ScriptDataEscaped;
                        } else {
                            self.state = .ScriptDataDoubleEscaped;
                        }
                        self.backlog.append(Token { .Character = .{ .data = next_char } }) catch unreachable;
                    },
                    else => {
                        if (std.ascii.isAlpha(next_char)) {
                            var lowered = std.ascii.toLower(next_char);
                            self.temporaryBuffer.append(lowered) catch unreachable;
                            self.backlog.append(Token { .Character = .{ .data = lowered } }) catch unreachable;
                        } else {
                            self.reconsume = true;
                            self.state = .ScriptDataDoubleEscaped;
                        }
                    }
                }
            },
            // 12.2.5.32 Before attribute name state
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
                        self.currentAttributeName.shrink(1);
                        self.currentAttributeName.append(self.currentChar()) catch unreachable;
                        self.currentAttributeValue.shrink(0);
                        self.state = .AttributeName;
                        return ParseError.UnexpectedEqualsSignBeforeAttributeName;
                    },
                    else => {
                        self.currentAttributeName.shrink(0);
                        self.currentAttributeValue.shrink(0);
                        self.state = .AttributeName;
                        self.reconsume = true;
                    }
                }
            },
            // 12.2.5.33 Attribute name state
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
                        self.currentAttributeName.appendSlice("�") catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    '"', '\'', '<' => {
                        self.currentAttributeName.append(next_char) catch unreachable;
                        return ParseError.UnexpectedCharacterInAttributeName;
                    },
                    else => {
                        next_char = std.ascii.toLower(next_char);
                        self.currentAttributeName.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.34 After attribute name state
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
                            .name = self.currentAttributeName.toOwnedSlice(),
                            .value = self.currentAttributeValue.toOwnedSlice(),
                        };
                        switch (self.currentToken.?) {
                            .StartTag => |*tag| {
                                tag.attributes.append(attr) catch unreachable;
                                tag.name = self.tokenData.toOwnedSlice();
                            },
                            .EndTag => |*tag| {
                                tag.attributes.append(attr) catch unreachable;
                                tag.name = self.tokenData.toOwnedSlice();
                            },
                            else => {}
                        }
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    else => {
                        self.currentAttributeName.shrink(0);
                        self.currentAttributeValue.shrink(0);
                        self.state = .AttributeName;
                        self.reconsume = true;
                    }
                }
            },
            // 12.2.5.35 Before attribute value state
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
                        switch (self.currentToken.?) {
                            .StartTag => |*tag| tag.name = self.tokenData.toOwnedSlice(),
                            .EndTag => |*tag| tag.name = self.tokenData.toOwnedSlice(),
                            else => {}
                        }
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                        return ParseError.MissingAttributeValue;
                    },
                    else => {
                        self.reconsume = true;
                        self.state = .AttributeValueUnquoted;
                    }
                }
            },
            // 12.2.5.36 Attribute value (double-quoted) state
            .AttributeValueDoubleQuoted => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '"' => {
                        self.state = .AfterAttributeValueQuoted;
                    },
                    // '&' => {
                    //     self.returnState = .AttributeValueDoubleQuoted;
                    //     self.state = .CharacterReference;
                    // },
                    0x00 => {
                        self.currentAttributeValue.appendSlice("�") catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.currentAttributeValue.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.37 Attribute value (single-quoted) state
            .AttributeValueSingleQuoted => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\'' => {
                        self.state = .AfterAttributeValueQuoted;
                    },
                    // '&' => {
                    //     self.returnState = .AttributeValueSingleQuoted;
                    //     self.state = .CharacterReference;
                    // },
                    0x00 => {
                        self.currentAttributeValue.appendSlice("�") catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.currentAttributeValue.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.38 Attribute value (unquoted) state
            .AttributeValueUnquoted => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ' => {
                        self.state = .BeforeAttributeName;
                    },
                    // '&' => {
                    //     self.returnState = .AttributeValueUnquoted;
                    //     self.state = .CharacterReference;
                    // },
                    '>' => {
                        switch (self.currentToken.?) {
                            .StartTag => |*tag| tag.name = self.tokenData.toOwnedSlice(),
                            .EndTag => |*tag| tag.name = self.tokenData.toOwnedSlice(),
                            else => {}
                        }
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    '"', '\'', '<', '=', '`' => {
                        self.currentAttributeValue.append(next_char) catch unreachable;
                        return ParseError.UnexpectedCharacterInUnquotedAttributeValue;
                    },
                    else => {
                        self.currentAttributeValue.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.39 After attribute value (quoted) state
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
                        switch (self.currentToken.?) {
                            .StartTag => |*tag| tag.name = self.tokenData.toOwnedSlice(),
                            .EndTag => |*tag| tag.name = self.tokenData.toOwnedSlice(),
                            else => {}
                        }
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    else => {
                        self.state = .BeforeAttributeName;
                        self.reconsume = true;
                    }
                }
            },
            // 12.2.5.40 Self-closing start tag state
            .SelfClosingStartTag => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '>' => {
                        switch (self.currentToken.?) {
                            .StartTag => |*tag| {
                                tag.selfClosing = true;
                                tag.name = self.tokenData.toOwnedSlice();
                            },
                            .EndTag => |*tag| {
                                tag.selfClosing = true;
                                tag.name = self.tokenData.toOwnedSlice();
                            },
                            else => {}
                        }
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    else => {
                        self.reconsume = true;
                        self.state = .BeforeAttributeName;
                        return ParseError.UnexpectedSolidusInTag;
                    }
                }
            },
            // 12.2.5.41 Bogus comment state
            .BogusComment => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '>' => {
                        self.state = .Data;
                    },
                    0x00 => {
                        self.commentData.appendSlice("�") catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.commentData.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.42 Markup declaration open state
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
            // 12.2.5.43 Comment start state
            .CommentStart => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .CommentStartDash;
                    },
                    '>' => {
                        self.state = .Data;  
                        self.backlog.append(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } }) catch unreachable;
                        return ParseError.AbruptClosingOfEmptyComment;
                    },
                    else => {
                        self.reconsume = true;
                        self.state = .Comment;
                    }
                }
            },
            // 12.2.5.44 Comment start dash state
            .CommentStartDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .CommentEnd;
                    },
                    '>' => {
                        self.state = .Data;  
                        self.backlog.append(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } }) catch unreachable;
                        return ParseError.AbruptClosingOfEmptyComment;
                    },
                    else => {
                        self.commentData.append('-') catch unreachable;
                        self.reconsume = true;
                        self.state = .Comment;
                    }
                }
            },
            // 12.2.5.45 Comment state
            .Comment => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '<' => {
                        self.commentData.append(next_char) catch unreachable;
                        self.state = .CommentLessThanSign;
                    },
                    '-' => {
                        self.state = .CommentEndDash;  
                    },
                    0x00 => {
                        self.commentData.appendSlice("�") catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        self.commentData.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.46 Comment less-than sign state
            .CommentLessThanSign => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '!' => {
                        self.commentData.append('!') catch unreachable;
                        self.state = .CommentLessThanSignBang;
                    },
                    '<' => {
                        self.commentData.append(next_char) catch unreachable;
                    },
                    else => {
                        self.reconsume = true;
                        self.state = .Comment;
                    }
                }
            },
            // 12.2.5.47 Comment less-than sign bang state
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
            // 12.2.5.48 Comment less-than sign bang dash state
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
            // 12.2.5.49 Comment less-than sign bang dash dash state
            .CommentLessThanSignBangDashDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '>' => {
                        self.reconsume = true;
                        self.state = .CommentEnd;
                    },
                    else => {
                        self.reconsume = true;
                        self.state = .CommentEnd;
                        return ParseError.NestedComment;
                    }
                }
            },
            // 12.2.5.50 Comment end dash state
            .CommentEndDash => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.state = .CommentEnd;
                    },
                    else => {
                        self.commentData.append(next_char) catch unreachable;
                        self.reconsume = true;
                        self.state = .Comment;
                    }
                }
            },
            // 12.2.5.51 Comment end state
            .CommentEnd => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '>' => {
                        self.state = .Data;
                        self.backlog.append(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } }) catch unreachable;
                    },
                    '!' => {
                        self.state = .CommentEndBang;
                    },
                    '-' => {
                        self.commentData.append(next_char) catch unreachable;
                    },
                    else => {
                        self.commentData.appendSlice("--") catch unreachable;
                        self.reconsume = true;
                        self.state = .Comment;
                    }
                }
            },
            // 12.2.5.52 Comment end bang state
            .CommentEndBang => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '-' => {
                        self.commentData.appendSlice("--!") catch unreachable;
                        self.state = .CommentEndDash;
                    },
                    '>' => {
                        self.state = .Data;
                        self.backlog.append(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } }) catch unreachable;
                        return ParseError.IncorrectlyClosedComment;
                    },
                    else => {
                        self.commentData.appendSlice("--!") catch unreachable;
                        self.reconsume = true;
                        self.state = .Comment;
                    }
                }
            },
            // 12.2.5.53 DOCTYPE state
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
                        self.state = .BeforeDOCTYPEName;
                        self.reconsume = true;
                        return ParseError.MissingWhitespaceBeforeDoctypeName;
                    }
                }
            },
            // 12.2.5.54 Before DOCTYPE name state
            .BeforeDOCTYPEName => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ' => {
                        // Ignore and do nothing.
                    },
                    0x00 => {
                        self.currentToken = Token { .DOCTYPE = .{ .name = "�" } };
                        self.state = .DOCTYPEName;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    '>' => {
                        self.currentToken = Token { .DOCTYPE = .{ .forceQuirks = true } };
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                        return ParseError.MissingDoctypeName;
                    },
                    else => {
                        next_char = std.ascii.toLower(next_char);
                        self.currentToken = Token { .DOCTYPE = .{ } };
                        self.tokenData.append(next_char) catch unreachable;
                        self.state = .DOCTYPEName;
                    }
                }
            },
            // 12.2.5.55 DOCTYPE name state
            .DOCTYPEName => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ' => {
                        self.state = .AfterDOCTYPEName;
                    },
                    '>' => {
                        var name = self.tokenData.toOwnedSlice();
                        self.currentToken.?.DOCTYPE.name = name;
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    0x00 => {
                        self.currentToken = Token { .DOCTYPE = .{ } };
                        self.tokenData.appendSlice("�") catch unreachable;
                        return ParseError.UnexpectedNullCharacter;
                    },
                    else => {
                        next_char = std.ascii.toLower(next_char);
                        self.currentToken = Token { .DOCTYPE = .{ } };
                        self.tokenData.append(next_char) catch unreachable;
                    }
                }
            },
            // 12.2.5.56 After DOCTYPE name state
            .AfterDOCTYPEName => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ' => {
                        // Ignore and do nothing.
                    },
                    '>' => {
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                    },
                    else => {
                        var next_six = self.peekN(6);
                        next_six = std.ascii.allocLowerString(self.allocator, next_six) catch unreachable;
                        if (mem.eql(u8, next_six, "public")) {
                            self.index += 6;
                            self.state = .AfterDOCTYPEPublicKeyword;
                        } else if (mem.eql(u8, next_six, "system")) {
                            self.index += 6; 
                            self.state = .AfterDOCTYPESystemKeyword;
                        } else {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.InvalidCharacterSequenceAfterDoctypeName;
                        }
                    }
                }
            },
            // 12.2.5.57 After DOCTYPE public keyword state
            .AfterDOCTYPEPublicKeyword => {
                var next_char = self.nextChar();
                switch (next_char) {
                    '\t', 0x0A, 0x0C, ' ' => {
                        self.state = .BeforeDOCTYPEPublicIdentifier;
                    },
                    '"' => {
                        self.publicIdentifier.shrink(0);
                        self.state = .DOCTYPEPublicIdentifierDoubleQuoted;
                        return ParseError.MissingWhitespaceAfterDoctypePublicKeyword;
                    },
                    '\'' => {
                        self.publicIdentifier.shrink(0);
                        self.state = .DOCTYPEPublicIdentifierSingleQuoted;
                        return ParseError.MissingWhitespaceAfterDoctypePublicKeyword;
                    },
                    '>' => {
                        self.currentToken.?.DOCTYPE.forceQuirks = true;
                        self.state = .Data;
                        self.backlog.append(self.currentToken.?) catch unreachable;
                        self.currentToken = null;
                        return ParseError.MissingDoctypePublicIdentifier;
                    },
                    else => {
                        self.currentToken.?.DOCTYPE.forceQuirks = true;
                        self.reconsume = true;
                        self.state = .BogusDOCTYPE;
                        return ParseError.MissingQuoteBeforeDoctypePublicIdentifier;
                    }
                }
            },
            // 12.2.5.58 Before DOCTYPE public identifier state
            .BeforeDOCTYPEPublicIdentifier => {
                unreachable;
            },
            // 12.2.5.59 DOCTYPE public identifier (double-quoted) state
            .DOCTYPEPublicIdentifierDoubleQuoted => {
                unreachable;
            },
            // 12.2.5.60 DOCTYPE public identifier (single-quoted) state
            .DOCTYPEPublicIdentifierSingleQuoted => {

            },
            // 12.2.5.61 After DOCTYPE public identifier state
            .AfterDOCTYPEPublicIdentifier => {
                unreachable;
            },
            // 12.2.5.62 Between DOCTYPE public and system identifiers state
            .BetweenDOCTYPEPublicAndSystemIdentifiers => {
                unreachable;
            },
            // 12.2.5.63 After DOCTYPE system keyword state
            .AfterDOCTYPESystemKeyword => {
                unreachable;
            },
            // 12.2.5.64 Before DOCTYPE system identifier state
            .BeforeDOCTYPESystemIdentifier => {
                unreachable;
            },
            // 12.2.5.65 DOCTYPE system identifier (double-quoted) state
            .DOCTYPESystemIdentifierDoubleQuoted => {
                unreachable;
            },
            // 12.2.5.66 DOCTYPE system identifier (single-quoted) state
            .DOCTYPESystemIdentifierSingleQuoted => {
                unreachable;
            },
            // 12.2.5.67 After DOCTYPE system identifier state
            .AfterDOCTYPESystemIdentifier => {
                unreachable;
            },
            // 12.2.5.68 Bogus DOCTYPE state
            .BogusDOCTYPE => {
                unreachable;
            },
            // 12.2.5.69 CDATA section state
            .CDATASection => {
                unreachable;
            },
            // 12.2.5.70 CDATA section bracket state
            .CDATASectionBracket => {
                unreachable;
            },
            // 12.2.5.71 CDATA section end state
            .CDATASectionEnd => {
                unreachable;
            },
            // 12.2.5.72 Character reference state
            .CharacterReference => {
                unreachable;
            },
            // 12.2.5.73 Named character reference state
            .NamedCharacterReference => {
                // TODO: I need a state machine generator of some kind.
                // https://github.com/adrian-thurston/ragel/issues/6
                unreachable;
            },
            // 12.2.5.74 Ambiguous ampersand state
            .AmbiguousAmpersand => {
                unreachable;
            },
            // 12.2.5.75 Numeric character reference state
            .NumericCharacterReference => {
                unreachable;
            },
            // 12.2.5.76 Hexadecimal character reference start state
            .HexadecimalCharacterReferenceStart => {
                unreachable;
            },
            // 12.2.5.77 Decimal character reference start state
            .DecimalCharacterReferenceStart => {
                unreachable;
            },
            // 12.2.5.78 Hexadecimal character reference state
            .HexadecimalCharacterReference => {
                unreachable;
            },
            // 12.2.5.79 Decimal character reference state
            .DecimalCharacterReference => {
                unreachable;
            },
            // 12.2.5.80 Numeric character reference end state
            .NumericCharacterReferenceEnd => {
                unreachable;
            }
        }

        return null;
    }

    pub fn eof(self: Self) bool {
        if (self.index >= self.contents.len) return true;
        return false;
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
};