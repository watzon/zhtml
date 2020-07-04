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

pub const ParseError = struct {
    kind: Type,
    line: usize,
    column: usize,
    
    const Type = enum {
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

    pub fn initStartTagToken(allocator: *mem.Allocator) Token {
        return Token{
            .kind = .StartTag,
            .attributes = ArrayList(Attribute).init(allocator),
        };
    }

    pub fn initEndTagToken(allocator: *mem.Allocator) Token {
        return Token{
            .kind = .EndTag,
            .attributes = ArrayList(Attribute).init(allocator),
        };
    }

    pub fn initCharacterToken(char: []const u8) Token {
        return Token{
            .kind = .Character,
            .data = char
        };
    }

    pub fn initNullCharacterToken() Token {
        return initCharacterToken(&[_]u8{ 0x00 });
    }

    pub fn deinit(self: *Token) void {
        if (!(self.attributes == null)) {
            self.attributes.?.allocator.free(self.attributes.?);
        }
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
    errors: ArrayList(ParseError),
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
        tokenizer.errors = ArrayList(ParseError).init(allocator);
        tokenizer.filename = filename;
        tokenizer.allocated = true;
        return tokenizer;
    }

    /// Create a new {{Tokenizer}} instance using a string.
    pub fn initWithString(allocator: *mem.Allocator, str: []const u8) !Tokenizer {
        return Tokenizer{
            .allocator = allocator,
            .allocated = false,
            .errors = ArrayList(ParseError).init(allocator),
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

    pub fn next(self: *Self) ?Token {
        var tokenData = ArrayList(u8).init(self.allocator);
        var temporaryBuffer = ArrayList(u8).init(self.allocator);
        var publicIdentifier = ArrayList(u8).init(self.allocator);
        var commentData = ArrayList(u8).init(self.allocator);
        var currentAttributeName = ArrayList(u8).init(self.allocator);
        var currentAttributeValue = ArrayList(u8).init(self.allocator);
        var currentToken: ?Token = null;

        while (true) {
            std.log.debug(.tokenizer, "{}\n", .{ self.state });
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
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initNullCharacterToken();
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
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
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
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
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
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
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.5 PLAINTEXT state
                .PLAINTEXT => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
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
                            self.parseError(.UnexpectedQuestionMarkInsteadOfTagName);                            
                            currentToken = Token{ .kind = .Comment };
                            self.state = .BogusComment;
                            self.reconsume = true;
                        },
                        else => {
                            if (std.ascii.isAlpha(next_char)) {
                                currentToken = Token.initStartTagToken(self.allocator);
                                self.state = .TagName;
                                self.reconsume = true;
                            } else {
                                self.parseError(.InvalidFirstCharacterOfTagName);
                                self.state = .Data;
                                self.reconsume = true;
                                return Token.initCharacterToken("<");
                            }
                        }
                    }
                },
                // 12.2.5.7 End tag open state
                .EndTagOpen => {
                    var next_char = self.nextChar();
                    if (next_char == '>') {
                        self.parseError(.MissingEndTagName);
                        self.state = .Data;
                    } else if (std.ascii.isAlpha(next_char)) {
                        currentToken = Token.initEndTagToken(self.allocator);
                        self.state = .TagName;
                        self.reconsume = true;
                    } else {
                        self.parseError(.InvalidFirstCharacterOfTagName);
                        currentToken = Token{ .kind = .Comment };
                        self.reconsume = true;
                        self.state = .BogusComment;
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
                            var name = tokenData.toOwnedSlice();
                            currentToken.?.name = name;
                            self.state = .Data;
                            return currentToken;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var lowered = std.ascii.toLower(next_char);
                            tokenData.append(lowered) catch unreachable;
                        }
                    }
                },
                // 12.2.5.9 RCDATA less-than sign state
                .RCDATALessThanSign => {
                    var next_char = self.nextChar();
                    if (next_char == '/') {
                        temporaryBuffer.shrink(0);
                        self.state = .RCDATAEndTagOpen;
                    } else {
                        self.reconsume = true;
                        self.state = .RCDATA;
                        return Token.initCharacterToken("<");
                    }
                },
                // 12.2.5.10 RCDATA end tag open state
                .RCDATAEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        currentToken = Token.initEndTagToken(self.allocator);
                    } else {
                        return Token.initCharacterToken("</");
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
                        temporaryBuffer.shrink(0);
                        self.state = .RAWTEXT;
                    } else {
                        self.reconsume = true;
                        self.state = .RAWTEXT;
                        return Token.initCharacterToken("<");
                    }
                },
                // 12.2.5.13 RAWTEXT end tag open state
                .RAWTEXTEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        self.reconsume = true;
                        self.state = .RAWTEXTEndTagName;
                        return Token.initEndTagToken(self.allocator);
                    } else {
                        self.reconsume = true;
                        self.state = .RAWTEXTEndTagName;
                        return Token.initCharacterToken("</");
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
                            temporaryBuffer.shrink(0);
                            self.state = .ScriptDataEndTagOpen;
                        },
                        '!' => {
                            self.state = .ScriptDataEscapeStart;
                            return Token.initCharacterToken("<!");
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .ScriptData;
                            return Token.initCharacterToken("<");
                        }
                    }
                },
                // 12.2.5.16 Script data end tag open state
                .ScriptDataEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        currentToken = Token.initEndTagToken(self.allocator);
                        self.reconsume = true;
                        self.state = .ScriptDataEndTagName;
                    } else {
                        self.reconsume = true;
                        self.state = .ScriptData;
                        return Token.initCharacterToken("</");
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
                        return Token.initCharacterToken("-");
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
                        return Token.initCharacterToken("-");
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
                            return Token.initCharacterToken("-");
                        },
                        '<' => {
                            self.state = .ScriptDataEscapedLessThanSign;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.21 Script data escaped dash state
                .ScriptDataEscapedDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .ScriptDataEscapedDashDash;
                            return Token.initCharacterToken("-");
                        },
                        '<' => {
                            self.state = .ScriptDataEscapedLessThanSign;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            self.state = .ScriptDataEscaped;
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.22 Script data escaped dash dash state
                .ScriptDataEscapedDashDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            return Token.initCharacterToken("-");
                        },
                        '<' => {
                            self.state = .ScriptDataEscapedLessThanSign;
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.state = .ScriptDataEscaped;
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            self.state = .ScriptDataEscaped;
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.23 Script data escaped less-than sign state
                .ScriptDataEscapedLessThanSign => {
                    var next_char = self.nextChar();
                    if (next_char == '/') {
                        temporaryBuffer.shrink(0);
                        self.state = .ScriptDataEscapedEndTagOpen;
                    } else if (std.ascii.isAlpha(next_char)) {
                        temporaryBuffer.shrink(0);
                        self.reconsume = true;
                        self.state = .ScriptDataDoubleEscapeStart;
                        return Token.initCharacterToken("<");
                    } else {
                        self.reconsume = true;
                        self.state = .ScriptDataEscaped;
                        return Token.initCharacterToken("<");
                    }
                },
                // 12.2.5.24 Script data escaped end tag open state
                .ScriptDataEscapedEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        currentToken = Token.initEndTagToken(self.allocator);
                        self.reconsume = true;
                        self.state = .ScriptDataEscapedEndTagName;
                    } else {
                        self.reconsume = true;
                        self.state = .ScriptDataEscaped;
                        return Token.initCharacterToken("</");
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
                            if (mem.eql(u8, temporaryBuffer.items, "script")) {
                                self.state = .ScriptDataDoubleEscaped;
                            } else {
                                self.state = .ScriptDataEscaped;
                            }
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        },
                        else => {
                            if (std.ascii.isAlpha(next_char)) {
                                var lowered = std.ascii.toLower(next_char);
                                temporaryBuffer.append(lowered) catch unreachable;
                                var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                                buffer[0] = lowered;
                                return Token.initCharacterToken(buffer);
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
                            return Token.initCharacterToken("-");
                        },
                        '<' => {
                            self.state = .ScriptDataDoubleEscapedLessThanSign;
                            return Token.initCharacterToken("<");
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.28 Script data double escaped dash state
                .ScriptDataDoubleEscapedDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .ScriptDataDoubleEscapedDashDash;
                            return Token.initCharacterToken("-");
                        },
                        '<' => {
                            self.state = .ScriptDataDoubleEscapedLessThanSign;
                            return Token.initCharacterToken("<");
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.state = .ScriptDataDoubleEscaped;
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            self.state = .ScriptDataDoubleEscaped;
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.29 Script data double escaped dash dash state
                .ScriptDataDoubleEscapedDashDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            return Token.initCharacterToken("-");
                        },
                        '<' => {
                            self.state = .ScriptDataDoubleEscapedLessThanSign;
                            return Token.initCharacterToken("<");
                        },
                        '>' => {
                            self.state = .ScriptData;
                            return Token.initCharacterToken(">");
                        },
                        0x00 => {
                            self.parseError(.UnexpectedNullCharacter);
                            self.state = .ScriptDataDoubleEscaped;
                            return Token.initCharacterToken("�");
                        },
                        else => {
                            self.state = .ScriptDataDoubleEscaped;
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        }
                    }
                },
                // 12.2.5.30 Script data double escaped less-than sign state
                .ScriptDataDoubleEscapedLessThanSign => {
                    var next_char = self.nextChar();
                    if (next_char == '/') {
                        temporaryBuffer.shrink(0);
                        self.state = .ScriptDataDoubleEscapeEnd;
                        return Token.initCharacterToken("/");
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
                            if (mem.eql(u8, temporaryBuffer.items, "script")) {
                                self.state = .ScriptDataEscaped;
                            } else {
                                self.state = .ScriptDataDoubleEscaped;
                            }
                            var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                            buffer[0] = next_char;
                            return Token.initCharacterToken(buffer);
                        },
                        else => {
                            if (std.ascii.isAlpha(next_char)) {
                                var lowered = std.ascii.toLower(next_char);
                                temporaryBuffer.append(lowered) catch unreachable;
                                var buffer = self.allocator.alloc(u8, 1) catch unreachable;
                                buffer[0] = lowered;
                                return Token.initCharacterToken(buffer);
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
                                .name = currentAttributeName.toOwnedSlice(),
                                .value = currentAttributeValue.toOwnedSlice(),
                            };
                            currentToken.?.attributes.?.append(attr) catch unreachable;
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.state = .Data;
                            return currentToken;
                        },
                        else => {
                            currentAttributeName.shrink(0);
                            currentAttributeValue.shrink(0);
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
                            self.parseError(.MissingAttributeValue);
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.state = .Data;
                            return currentToken;
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
                            self.parseError(.UnexpectedNullCharacter);
                            currentAttributeValue.appendSlice("�") catch unreachable;
                        },
                        else => {
                            currentAttributeValue.append(next_char) catch unreachable;
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
                            self.parseError(.UnexpectedNullCharacter);
                            currentAttributeValue.appendSlice("�") catch unreachable;
                        },
                        else => {
                            currentAttributeValue.append(next_char) catch unreachable;
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
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.state = .Data;
                            return currentToken;
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
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.state = .Data;
                            return currentToken;
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
                            currentToken.?.selfClosing = true;
                            currentToken.?.name = tokenData.toOwnedSlice();
                            self.state = .Data;
                            return currentToken;
                        },
                        else => {
                            self.parseError(.UnexpectedSolidusInTag);
                            self.reconsume = true;
                            self.state = .BeforeAttributeName;
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
                            self.parseError(.UnexpectedNullCharacter);
                            commentData.appendSlice("�") catch unreachable;
                        },
                        else => {
                            commentData.append(next_char) catch unreachable;
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
                            self.parseError(.AbruptClosingOfEmptyComment);
                            self.state = .Data;  
                            return Token{ .kind = .Comment, .data = commentData.toOwnedSlice() };
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
                            self.parseError(.AbruptClosingOfEmptyComment);
                            self.state = .Data;  
                            return Token{ .kind = .Comment, .data = commentData.toOwnedSlice() };
                        },
                        else => {
                            commentData.append('-') catch unreachable;
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
                // 12.2.5.46 Comment less-than sign state
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
                            self.parseError(.NestedComment);
                            self.reconsume = true;
                            self.state = .CommentEnd;
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
                            commentData.append(next_char) catch unreachable;
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
                            return Token{ .kind = .Comment, .data = commentData.toOwnedSlice() };
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
                // 12.2.5.52 Comment end bang state
                .CommentEndBang => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            commentData.appendSlice("--!") catch unreachable;
                            self.state = .CommentEndDash;
                        },
                        '>' => {
                            self.parseError(.IncorrectlyClosedComment);
                            self.state = .Data;
                            return Token{ .kind = .Comment, .data = commentData.toOwnedSlice() };
                        },
                        else => {
                            commentData.appendSlice("--!") catch unreachable;
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
                            self.parseError(.MissingWhitespaceBeforeDoctypeName);
                            self.state = .BeforeDOCTYPEName;
                            self.reconsume = true;
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
                            self.parseError(.UnexpectedNullCharacter);
                            currentToken = Token{ .kind = .DOCTYPE };
                            currentToken.?.name = "�";
                            self.state = .DOCTYPEName;
                        },
                        '>' => {
                            self.parseError(.MissingDoctypeName);
                            currentToken = Token{ .kind = .DOCTYPE };
                            currentToken.?.forceQuirks = true;
                            self.state = .Data;
                            return currentToken;
                        },
                        else => {
                            next_char = std.ascii.toLower(next_char);
                            currentToken = Token{ .kind = .DOCTYPE };
                            tokenData.append(next_char) catch unreachable;
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
                            var name = tokenData.toOwnedSlice();
                            currentToken.?.name = name;
                            self.state = .Data;
                            return currentToken;
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
                // 12.2.5.56 After DOCTYPE name state
                .AfterDOCTYPEName => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing.
                        },
                        '>' => {
                            self.state = .Data;
                            return currentToken;
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
                                self.parseError(.InvalidCharacterSequenceAfterDoctypeName);
                                currentToken.?.forceQuirks = true;
                                self.reconsume = true;
                                self.state = .BogusDOCTYPE;
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
                            self.parseError(.MissingWhitespaceAfterDoctypePublicKeyword);
                            publicIdentifier.shrink(0);
                            self.state = .DOCTYPEPublicIdentifierDoubleQuoted;
                        },
                        '\'' => {
                            self.parseError(.MissingWhitespaceAfterDoctypePublicKeyword);
                            publicIdentifier.shrink(0);
                            self.state = .DOCTYPEPublicIdentifierSingleQuoted;
                        },
                        '>' => {
                            self.parseError(.MissingDoctypePublicIdentifier);
                            currentToken.?.forceQuirks = true;
                            self.state = .Data;
                            return currentToken;
                        },
                        else => {
                            self.parseError(.MissingQuoteBeforeDoctypePublicIdentifier);
                            currentToken.?.forceQuirks = true;
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
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
                    temporaryBuffer.shrink(0);
                    temporaryBuffer.append('&') catch unreachable;
                    var next_char = self.nextChar();
                    if (std.ascii.isAlNum(next_char)) {
                        self.reconsume = true;
                        self.state = .NamedCharacterReference;
                    } else if (next_char == '#') {
                        temporaryBuffer.append(next_char) catch unreachable;
                        self.state = .NamedCharacterReference;
                    } else {
                        switch (self.returnState.?) {
                            .AttributeValueDoubleQuoted, .AttributeValueSingleQuoted, .AttributeValueUnquoted => {
                                currentAttributeValue.appendSlice(temporaryBuffer.toOwnedSlice()) catch unreachable;
                            },
                            else => {
                                return Token.initCharacterToken(temporaryBuffer.toOwnedSlice());
                            }
                        }
                    }
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
        }

        // We're done tokenizing, so emit the final EOF token.
        self.emitEofToken();
    }

    pub fn eof(self: Self) bool {
        if (self.index >= self.contents.len) return true;
        return false;
    }

    fn parseError(self: *Self, kind: ParseError.Type) void {
        var err = ParseError{
            .kind = kind,
            .line = self.line,
            .column = self.column,
        };

        self.errors.append(err) catch unreachable;
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