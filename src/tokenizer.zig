const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const StringHashMap = std.hash_map.StringHashMap;
const LinearFifo = std.fifo.LinearFifo;

const Token = @import("token.zig").Token;
const ParseError = @import("parse_error.zig").ParseError;
const buildNamedCharacterReferenceTable = @import("namedCharacterReference.zig").buildNamedCharacterReferenceTable;

/// Represents the state of the HTML tokenizer as described
/// [here](https://html.spec.whatwg.org/multipage/parsing.html#tokenization)
pub const Tokenizer = struct {
    const Self = @This();

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

    // Intermediate type necessary to be able to store ParseError's in a LinearFifo
    // See https://github.com/ziglang/zig/issues/5820
    const ParseErrorIntType = std.meta.IntType(false, @sizeOf(anyerror) * 8);
    
    allocator: *mem.Allocator,
    state: State = .Data,
    returnState: ?State = null,
    // TODO: This could potentially use .Static if we can guarantee some maximum number of tokens emitted at a time
    backlog: LinearFifo(Token, .Dynamic),
    errorQueue: LinearFifo(ParseErrorIntType, .Dynamic),
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
    systemIdentifier: ArrayList(u8),
    commentData: ArrayList(u8),
    currentAttributeName: ArrayList(u8),
    currentAttributeValue: ArrayList(u8),
    currentToken: ?Token = null,
    characterReferenceCode: usize = 0,
    namedCharacterReferenceTable: StringHashMap(u21),

    /// Create a new {{Tokenizer}} instance using a file.
    pub fn initWithFile(allocator: *mem.Allocator, filename: []const u8) !Tokenizer {
        var contents = try std.fs.cwd().readFileAlloc(allocator, filename, std.math.maxInt(usize));
        var tokenizer = try Tokenizer.initWithString(allocator, contents);
        tokenizer.backlog = LinearFifo(Token, .Dynamic).init(allocator);
        tokenizer.errorQueue = LinearFifo(ParseErrorIntType, .Dynamic).init(allocator);
        tokenizer.filename = filename;
        tokenizer.allocated = true;
        tokenizer.tokenData = ArrayList(u8).init(allocator);
        tokenizer.temporaryBuffer = ArrayList(u8).init(allocator);
        tokenizer.publicIdentifier = ArrayList(u8).init(allocator);
        tokenizer.systemIdentifier = ArrayList(u8).init(allocator);
        tokenizer.commentData = ArrayList(u8).init(allocator);
        tokenizer.currentAttributeName = ArrayList(u8).init(allocator);
        tokenizer.currentAttributeValue = ArrayList(u8).init(allocator);
        tokenizer.namedCharacterReferenceTable = buildNamedCharacterReferenceTable(allocator);
        return tokenizer;
    }

    /// Create a new {{Tokenizer}} instance using a string.
    pub fn initWithString(allocator: *mem.Allocator, str: []const u8) !Tokenizer {
        return Tokenizer{
            .allocator = allocator,
            .allocated = false,
            .backlog = LinearFifo(Token, .Dynamic).init(allocator),
            .errorQueue = LinearFifo(ParseErrorIntType, .Dynamic).init(allocator),
            .tokenData = ArrayList(u8).init(allocator),
            .temporaryBuffer = ArrayList(u8).init(allocator),
            .publicIdentifier = ArrayList(u8).init(allocator),
            .systemIdentifier = ArrayList(u8).init(allocator),
            .commentData = ArrayList(u8).init(allocator),
            .currentAttributeName = ArrayList(u8).init(allocator),
            .currentAttributeValue = ArrayList(u8).init(allocator),
            .namedCharacterReferenceTable = buildNamedCharacterReferenceTable(allocator),
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

    /// null being returned always signifies EOF
    pub fn nextToken(self: *Self) ParseError!?Token {
        // Clear out any backlog before continuing
        if (self.popQueuedErrorOrToken()) |optional_token| {
            if (optional_token != null) {
                return optional_token;
            }
        } else |err| {
            return err;
        }

        // Check if we're at the EndOfFile. If so, for now, just return an
        // EndOfFile token, but later we'll need to do specific checking inside
        // of the below switch statement.
        if (self.eof()) {
            std.debug.print("self.eof() == true\n", .{});
            return null;
        }

        while (true) {
            switch (self.state) {
                // 12.2.5.1 Data state
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
                            self.emitToken(Token { .Character = .{ .data = 0x00  } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.2 RCDATA state
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
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.5 PLAINTEXT state
                .PLAINTEXT => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        0x00 => {
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
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
                                self.currentToken = Token { .StartTag = .{ .attributes = StringHashMap([]const u8).init(self.allocator) } };
                                self.state = .TagName;
                                self.reconsume = true;
                            } else {
                                self.state = .Data;
                                self.reconsume = true;
                                self.emitToken(Token { .Character = .{ .data = '<' } });
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
                        self.currentToken = Token { .EndTag = .{ .attributes = StringHashMap([]const u8).init(self.allocator) } };
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
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        0x00 => {
                            self.emitToken(Token { .Character = .{ .data = '�' } });
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
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        return self.popQueuedErrorOrToken();
                    }
                },
                // 12.2.5.10 RCDATA end tag open state
                .RCDATAEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        self.currentToken = Token{ .EndTag = .{ .attributes = StringHashMap([]const u8).init(self.allocator) } };
                    } else {
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        self.emitToken(Token { .Character = .{ .data = '/' } });
                        return self.popQueuedErrorOrToken();
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
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        return self.popQueuedErrorOrToken();
                    }
                },
                // 12.2.5.13 RAWTEXT end tag open state
                .RAWTEXTEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        self.reconsume = true;
                        self.state = .RAWTEXTEndTagName;
                        self.emitToken(Token { .EndTag = .{ .attributes = StringHashMap([]const u8).init(self.allocator) } } );
                        return self.popQueuedErrorOrToken();
                    } else {
                        self.reconsume = true;
                        self.state = .RAWTEXTEndTagName;
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        self.emitToken(Token { .Character = .{ .data = '/' } });
                        return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = '<' } });
                            self.emitToken(Token { .Character = .{ .data = '!' } });
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .ScriptData;
                            self.emitToken(Token { .Character = .{ .data = '<' } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.16 Script data end tag open state
                .ScriptDataEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        self.currentToken = Token { .EndTag = .{ .attributes = StringHashMap([]const u8).init(self.allocator) } };
                        self.reconsume = true;
                        self.state = .ScriptDataEndTagName;
                    } else {
                        self.reconsume = true;
                        self.state = .ScriptData;
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        self.emitToken(Token { .Character = .{ .data = '/' } });
                        return self.popQueuedErrorOrToken();
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
                        self.emitToken(Token { .Character = .{ .data = '-' } });
                        return self.popQueuedErrorOrToken();
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
                        self.emitToken(Token { .Character = .{ .data = '-' } });
                        return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = '-' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '<' => {
                            self.state = .ScriptDataEscapedLessThanSign;
                        },
                        0x00 => {
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.21 Script data escaped dash state
                .ScriptDataEscapedDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .ScriptDataEscapedDashDash;
                            self.emitToken(Token { .Character = .{ .data = '-' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '<' => {
                            self.state = .ScriptDataEscapedLessThanSign;
                        },
                        0x00 => {
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.state = .ScriptDataEscaped;
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.22 Script data escaped dash dash state
                .ScriptDataEscapedDashDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.emitToken(Token { .Character = .{ .data = '-' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '<' => {
                            self.state = .ScriptDataEscapedLessThanSign;
                        },
                        0x00 => {
                            self.state = .ScriptDataEscaped;
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.state = .ScriptDataEscaped;
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
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
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        return self.popQueuedErrorOrToken();
                    } else {
                        self.reconsume = true;
                        self.state = .ScriptDataEscaped;
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        return self.popQueuedErrorOrToken();
                    }
                },
                // 12.2.5.24 Script data escaped end tag open state
                .ScriptDataEscapedEndTagOpen => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlpha(next_char)) {
                        self.currentToken = Token { .EndTag = .{ .attributes = StringHashMap([]const u8).init(self.allocator) } };
                        self.reconsume = true;
                        self.state = .ScriptDataEscapedEndTagName;
                    } else {
                        self.reconsume = true;
                        self.state = .ScriptDataEscaped;
                        self.emitToken(Token { .Character = .{ .data = '<' } });
                        self.emitToken(Token { .Character = .{ .data = '/' } });
                        return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            if (std.ascii.isAlpha(next_char)) {
                                var lowered = std.ascii.toLower(next_char);
                                self.temporaryBuffer.append(lowered) catch unreachable;
                                self.emitToken(Token { .Character = .{ .data = lowered } });
                                return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = '-' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '<' => {
                            self.state = .ScriptDataDoubleEscapedLessThanSign;
                            self.emitToken(Token { .Character = .{ .data = '<' } });
                            return self.popQueuedErrorOrToken();
                        },
                        0x00 => {
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.28 Script data double escaped dash state
                .ScriptDataDoubleEscapedDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.state = .ScriptDataDoubleEscapedDashDash;
                            self.emitToken(Token { .Character = .{ .data = '-' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '<' => {
                            self.state = .ScriptDataDoubleEscapedLessThanSign;
                            self.emitToken(Token { .Character = .{ .data = '<' } });
                            return self.popQueuedErrorOrToken();
                        },
                        0x00 => {
                            self.state = .ScriptDataDoubleEscaped;
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.state = .ScriptDataDoubleEscaped;
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.29 Script data double escaped dash dash state
                .ScriptDataDoubleEscapedDashDash => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '-' => {
                            self.emitToken(Token { .Character = .{ .data = '-' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '<' => {
                            self.state = .ScriptDataDoubleEscapedLessThanSign;
                            self.emitToken(Token { .Character = .{ .data = '<' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '>' => {
                            self.state = .ScriptData;
                            self.emitToken(Token { .Character = .{ .data = '>' } });
                            return self.popQueuedErrorOrToken();
                        },
                        0x00 => {
                            self.state = .ScriptDataDoubleEscaped;
                            self.emitToken(Token { .Character = .{ .data = '�' } });
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            self.state = .ScriptDataDoubleEscaped;
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.30 Script data double escaped less-than sign state
                .ScriptDataDoubleEscapedLessThanSign => {
                    var next_char = self.nextChar();
                    if (next_char == '/') {
                        self.temporaryBuffer.shrink(0);
                        self.state = .ScriptDataDoubleEscapeEnd;
                        self.emitToken(Token { .Character = .{ .data = '/' } });
                        return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            if (std.ascii.isAlpha(next_char)) {
                                var lowered = std.ascii.toLower(next_char);
                                self.temporaryBuffer.append(lowered) catch unreachable;
                                self.emitToken(Token { .Character = .{ .data = lowered } });
                                return self.popQueuedErrorOrToken();
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
                            self.currentAttributeName.shrink(0);
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
                            self.addAttributeToCurrentToken();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
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
                            self.addAttributeToCurrentToken();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
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
                        '&' => {
                            self.returnState = .AttributeValueDoubleQuoted;
                            self.state = .CharacterReference;
                        },
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
                        '&' => {
                            self.returnState = .AttributeValueSingleQuoted;
                            self.state = .CharacterReference;
                        },
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
                        '&' => {
                            self.returnState = .AttributeValueUnquoted;
                            self.state = .CharacterReference;
                        },
                        '>' => {
                            self.addAttributeToCurrentToken();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
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
                    self.addAttributeToCurrentToken();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BeforeAttributeName;
                        },
                        '/' => {
                            self.state = .SelfClosingStartTag;
                        },
                        '>' => {
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
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
                    self.addAttributeToCurrentToken();
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
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } });
                            return self.popQueuedErrorOrToken();
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
                    var lowered = std.ascii.allocLowerString(self.allocator, next_seven) catch unreachable;

                    if (mem.eql(u8, next_seven[0..2], "--")) {
                        self.index += 2;
                        self.state = .CommentStart;
                    } else if (mem.eql(u8, lowered, "doctype")) {
                        self.index += 7;
                        self.state = .DOCTYPE;
                    } else if (mem.eql(u8, next_seven, "[CDATA[")) {
                        // FIXME: Consume those characters. If there is an adjusted current node and it is not
                        // an element in the HTML namespace, then switch to the CDATA section state.
                        self.index += 7;
                        self.emitToken(Token { .Comment = .{ .data = "[CDATA[" } });
                        self.state = .BogusComment;
                        return ParseError.CDATAInHtmlContent;
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
                            self.emitToken(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } });
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
                            self.emitToken(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } });
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
                            self.emitToken(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } });
                            return self.popQueuedErrorOrToken();
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
                            self.emitToken(Token { .Comment = .{ .data = self.commentData.toOwnedSlice() } });
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
                            self.emitToken(self.currentToken.?);
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
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
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
                    var next_char = self.peekChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.index += 1;
                        },
                        '>' => {
                            self.index += 1;
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
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
                                self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                                self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                                self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
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
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return ParseError.MissingDoctypePublicIdentifier;
                        },
                        else => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.MissingQuoteBeforeDoctypePublicIdentifier;
                        }
                    }
                },
                // 12.2.5.58 Before DOCTYPE public identifier state
                .BeforeDOCTYPEPublicIdentifier => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing
                        },
                        '"' => {
                            self.publicIdentifier.shrink(0);
                            self.state = .DOCTYPEPublicIdentifierDoubleQuoted;
                        },
                        '\'' => {
                            self.publicIdentifier.shrink(0);
                            self.state = .DOCTYPEPublicIdentifierSingleQuoted;
                        },
                        '>' => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.MissingQuoteBeforeDoctypePublicIdentifier;
                        }
                    }
                },
                // 12.2.5.59 DOCTYPE public identifier (double-quoted) state
                .DOCTYPEPublicIdentifierDoubleQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '"' => {
                            self.state = .AfterDOCTYPEPublicIdentifier;
                        },
                        0x00 => {
                            self.publicIdentifier.appendSlice("�") catch unreachable;
                            return ParseError.UnexpectedNullCharacter;
                        },
                        '>' => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return ParseError.AbruptDoctypePublicIdentifier;
                        },
                        else => {
                            self.publicIdentifier.append(next_char) catch unreachable;
                        }
                    }
                },
                // 12.2.5.60 DOCTYPE public identifier (single-quoted) state
                .DOCTYPEPublicIdentifierSingleQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\'' => {
                            self.state = .AfterDOCTYPEPublicIdentifier;
                        },
                        0x00 => {
                            self.publicIdentifier.appendSlice("�") catch unreachable;
                            return ParseError.UnexpectedNullCharacter;
                        },
                        '>' => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return ParseError.AbruptDoctypePublicIdentifier;
                        },
                        else => {
                            self.publicIdentifier.append(next_char) catch unreachable;
                        }
                    }
                },
                // 12.2.5.61 After DOCTYPE public identifier state
                .AfterDOCTYPEPublicIdentifier => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BetweenDOCTYPEPublicAndSystemIdentifiers;
                        },
                        '>' => {
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        '"' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierDoubleQuoted;
                            return ParseError.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers;
                        },
                        '\'' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierSingleQuoted;
                            return ParseError.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers;
                        },
                        else => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.MissingQuoteBeforeDoctypeSystemIdentifier;
                        }
                    }
                },
                // 12.2.5.62 Between DOCTYPE public and system identifiers state
                .BetweenDOCTYPEPublicAndSystemIdentifiers => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing
                        },
                        '>' => {
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        '"' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierDoubleQuoted;
                        },
                        '\'' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierSingleQuoted;
                        },
                        else => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.MissingQuoteBeforeDoctypeSystemIdentifier;
                        }
                    }
                },
                // 12.2.5.63 After DOCTYPE system keyword state
                .AfterDOCTYPESystemKeyword => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            self.state = .BeforeDOCTYPESystemIdentifier;
                        },
                        '"' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierDoubleQuoted;
                            return ParseError.MissingWhitespaceAfterDoctypeSystemKeyword;
                        },
                        '\'' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierSingleQuoted;
                            return ParseError.MissingWhitespaceAfterDoctypeSystemKeyword;
                        },
                        '>' => {
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return ParseError.MissingDoctypeSystemIdentifier;
                        },
                        else => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.MissingQuoteBeforeDoctypeSystemIdentifier;
                        }
                    }
                },
                // 12.2.5.64 Before DOCTYPE system identifier state
                .BeforeDOCTYPESystemIdentifier => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing
                        },
                        '"' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierDoubleQuoted;
                        },
                        '\'' => {
                            self.systemIdentifier.shrink(0);
                            self.state = .DOCTYPESystemIdentifierSingleQuoted;
                        },
                        '>' => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.MissingQuoteBeforeDoctypeSystemIdentifier;
                        }
                    }
                },
                // 12.2.5.65 DOCTYPE system identifier (double-quoted) state
                .DOCTYPESystemIdentifierDoubleQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '"' => {
                            self.state = .AfterDOCTYPESystemIdentifier;
                        },
                        0x00 => {
                            self.systemIdentifier.appendSlice("�") catch unreachable;
                            return ParseError.UnexpectedNullCharacter;
                        },
                        '>' => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return ParseError.AbruptDoctypeSystemIdentifier;
                        },
                        else => {
                            self.systemIdentifier.append(next_char) catch unreachable;
                        }
                    }
                },
                // 12.2.5.66 DOCTYPE system identifier (single-quoted) state
                .DOCTYPESystemIdentifierSingleQuoted => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\'' => {
                            self.state = .AfterDOCTYPESystemIdentifier;
                        },
                        0x00 => {
                            self.systemIdentifier.appendSlice("�") catch unreachable;
                            return ParseError.UnexpectedNullCharacter;
                        },
                        '>' => {
                            self.currentToken.?.DOCTYPE.forceQuirks = true;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.systemIdentifier.toOwnedSlice();
                            self.state = .Data;
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return ParseError.AbruptDoctypeSystemIdentifier;
                        },
                        else => {
                            self.systemIdentifier.append(next_char) catch unreachable;
                        }
                    }
                },
                // 12.2.5.67 After DOCTYPE system identifier state
                .AfterDOCTYPESystemIdentifier => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '\t', 0x0A, 0x0C, ' ' => {
                            // Ignore and do nothing
                        },
                        '>' => {
                            self.state = .Data;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.systemIdentifier.toOwnedSlice();
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .BogusDOCTYPE;
                            return ParseError.UnexpectedCharacterAfterDoctypeSystemIdentifier;
                        }
                    }
                },
                // 12.2.5.68 Bogus DOCTYPE state
                .BogusDOCTYPE => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '>' => {
                            self.state = .Data;
                            self.currentToken.?.DOCTYPE.name = self.tokenData.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.publicIdentifier = self.publicIdentifier.toOwnedSlice();
                            self.currentToken.?.DOCTYPE.systemIdentifier = self.systemIdentifier.toOwnedSlice();
                            self.emitToken(self.currentToken.?);
                            self.currentToken = null;
                            return self.popQueuedErrorOrToken();
                        },
                        0x00 => {
                            return ParseError.UnexpectedNullCharacter;
                        },
                        else => {
                            // Ignore and do nothing
                        }
                    }
                },
                // 12.2.5.69 CDATA section state
                .CDATASection => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        '[' => {
                            self.state = .CDATASectionBracket;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.70 CDATA section bracket state
                .CDATASectionBracket => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        ']' => {
                            self.emitToken(Token { .Character = .{ .data = ']' } });
                            return self.popQueuedErrorOrToken();
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = ']' } });
                            self.emitToken(Token { .Character = .{ .data = ']' } });
                            self.reconsume = true;
                            self.state = .CDATASection;
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.71 CDATA section end state
                .CDATASectionEnd => {
                    var next_char = self.nextChar();
                    switch (next_char) {
                        ']' => {
                            self.emitToken(Token { .Character = .{ .data = ']' } });
                            return self.popQueuedErrorOrToken();
                        },
                        '>' => {
                            self.state = .Data;
                        },
                        else => {
                            self.emitToken(Token { .Character = .{ .data = ']' } });
                            self.emitToken(Token { .Character = .{ .data = ']' } });
                            self.reconsume = true;
                            self.state = .CDATASection;
                            return self.popQueuedErrorOrToken();
                        }
                    }
                },
                // 12.2.5.72 Character reference state
                .CharacterReference => {
                    self.temporaryBuffer.shrink(0);
                    // self.temporaryBuffer.append('&') catch unreachable;
                    var next_char = self.nextChar();
                    if (std.ascii.isAlNum(next_char)) {
                        self.reconsume = true;
                        self.state = .NamedCharacterReference;
                    } else if (next_char == '#') {
                        self.temporaryBuffer.append(next_char) catch unreachable;
                        self.state = .NumericCharacterReference;
                    } else {
                        const emitted = self.flushTemporaryBufferAsCharacterReference();
                        self.reconsume = true;
                        self.state = self.returnState.?;
                        if (emitted)
                            return self.popQueuedErrorOrToken();
                    }
                },
                // 12.2.5.73 Named character reference state
                .NamedCharacterReference => {
                    var next_char = self.nextChar();
                    const peeked = self.peekChar();
                    
                    // Read input characters until the next_char is not alpha-numeric
                    // TODO: This should actually only be matching prefixes of valid character references
                    //       See the example in 12.2.5.73
                    while (std.ascii.isAlNum(next_char)) : (next_char = self.nextChar())
                        self.temporaryBuffer.append(next_char) catch unreachable;
                    self.temporaryBuffer.append(next_char) catch unreachable;

                    const collected = self.temporaryBuffer.items;
                    if (self.namedCharacterReferenceTable.contains(collected)) {
                        if (self.inAttributeState() and next_char != ';' and (std.ascii.isAlNum(peeked) or peeked == '=')) {
                            const emitted = self.flushTemporaryBufferAsCharacterReference();
                            self.state = self.returnState.?;
                            if (emitted)
                                return self.popQueuedErrorOrToken();
                        } else {
                            const ncr = self.temporaryBuffer.toOwnedSlice();
                            const codepoint = self.namedCharacterReferenceTable.get(ncr).?;
                            
                            const emitted = self.flushCodepointAsCharacterReference(codepoint);
                            self.state = self.returnState.?;

                            if (self.currentChar() != ';')
                                return ParseError.MissingSemicolonAfterCharacterReference;
                            if (emitted)
                                return self.popQueuedErrorOrToken();
                        }
                    } else {
                        const emitted = self.flushTemporaryBufferAsCharacterReference();
                        self.state = .AmbiguousAmpersand;
                        if (emitted)
                            return self.popQueuedErrorOrToken();
                    }
                },
                // 12.2.5.74 Ambiguous ampersand state
                .AmbiguousAmpersand => {
                    var next_char = self.nextChar();
                    if (std.ascii.isAlNum(next_char)) {
                        if (self.inAttributeState()) {
                            self.currentAttributeValue.append(next_char) catch unreachable;
                        } else {
                            self.emitToken(Token { .Character = .{ .data = next_char } });
                            return self.popQueuedErrorOrToken();
                        }
                    } else if (next_char == ';') {
                        self.reconsume = true;
                        self.state = self.returnState.?;
                        return ParseError.UnknownNamedCharacterReference;
                    } else {
                        self.reconsume = true;
                        self.state = self.returnState.?;
                    }
                },
                // 12.2.5.75 Numeric character reference state
                .NumericCharacterReference => {
                    self.characterReferenceCode = 0;
                    var next_char = self.nextChar();
                    switch (next_char) {
                        'X', 'x' => {
                            self.temporaryBuffer.append(next_char) catch unreachable;
                            self.state = .HexadecimalCharacterReference;
                        },
                        else => {
                            self.reconsume = true;
                            self.state = .DecimalCharacterReferenceStart;
                        }
                    }
                },
                // 12.2.5.76 Hexadecimal character reference start state
                .HexadecimalCharacterReferenceStart => {
                    var next_char = self.nextChar();
                    if (std.ascii.isDigit(next_char)) {
                        self.reconsume = true;
                        self.state = .HexadecimalCharacterReference;
                    } else {
                        self.temporaryBuffer.shrink(0);
                        self.reconsume = true;
                        self.state = self.returnState.?;
                        return ParseError.AbsenceOfDigitsInNumericCharacterReference;
                    }
                },
                // 12.2.5.77 Decimal character reference start state
                .DecimalCharacterReferenceStart => {
                    var next_char = self.nextChar();
                    if (std.ascii.isDigit(next_char)) {
                        self.reconsume = true;
                        self.state = .DecimalCharacterReference;
                    } else {
                        self.temporaryBuffer.shrink(0);
                        self.reconsume = true;
                        self.state = self.returnState.?;
                        return ParseError.AbsenceOfDigitsInNumericCharacterReference;
                    }
                },
                // 12.2.5.78 Hexadecimal character reference state
                .HexadecimalCharacterReference => {
                    var next_char = self.nextChar();
                    if (std.ascii.isDigit(next_char)) {
                        self.characterReferenceCode *= 16;
                        self.characterReferenceCode += (next_char - 0x0030);
                    } else if (std.ascii.isXDigit(next_char)) {
                        self.characterReferenceCode *= 16;
                        if (std.ascii.isUpper(next_char)) {
                            self.characterReferenceCode += (next_char - 0x0037);
                        } else {
                            self.characterReferenceCode += (next_char - 0x0057);
                        }
                    } else if (next_char == ';') {
                        self.state = .NumericCharacterReferenceEnd;
                    } else {
                        self.reconsume = true;
                        self.state = .NumericCharacterReferenceEnd;
                        return ParseError.MissingSemicolonAfterCharacterReference;
                    }
                },
                // 12.2.5.79 Decimal character reference state
                .DecimalCharacterReference => {
                    var next_char = self.nextChar();
                    if (std.ascii.isDigit(next_char)) {
                        self.characterReferenceCode *= 10;
                        self.characterReferenceCode += (next_char - 0x0030);
                    } else if (next_char == ';') {
                        self.state = .NumericCharacterReferenceEnd;
                    } else {
                        self.temporaryBuffer.shrink(0);
                        self.reconsume = true;
                        self.state = .NumericCharacterReferenceEnd;
                        return ParseError.MissingSemicolonAfterCharacterReference;
                    }
                },
                // 12.2.5.80 Numeric character reference end state
                .NumericCharacterReferenceEnd => {
                    var err: ?ParseError = null;
                    switch (self.characterReferenceCode) {
                        0x00 => {
                            self.characterReferenceCode = 0xFFFD;
                            err = ParseError.NullCharacterReference;
                        },
                        0xD800...0xDFFF => {
                            self.characterReferenceCode = 0xFFFD;
                            err = ParseError.SurrogateCharacterReference;
                        },
                        0xFDD0...0xFDEF, 0xFFFE, 0xFFFF, 0x1FFFE, 0x1FFFF, 0x2FFFE, 0x2FFFF,
                        0x3FFFE, 0x3FFFF, 0x4FFFE, 0x4FFFF, 0x5FFFE, 0x5FFFF, 0x6FFFE, 0x6FFFF,
                        0x7FFFE, 0x7FFFF, 0x8FFFE, 0x8FFFF, 0x9FFFE, 0x9FFFF, 0xAFFFE, 0xAFFFF,
                        0xBFFFE, 0xBFFFF, 0xCFFFE, 0xCFFFF, 0xDFFFE, 0xDFFFF, 0xEFFFE, 0xEFFFF,
                        0xFFFFE, 0xFFFFF, 0x10FFFE, 0x10FFFF => {
                            err = ParseError.NoncharacterCharacterReference;
                        },
                        0x0001...0x001F, 0x007F...0x009F => {
                            // TODO: Match against the control character reference code.
                            err = ParseError.ControlCharacterReference;
                        },
                        else => {
                            if (self.characterReferenceCode > 0x10FFFF) {
                                self.characterReferenceCode = 0xFFFD;
                                err = ParseError.CharacterReferenceOutsideUnicodeRange;
                            }
                        }
                    }
                    const codepoint = @intCast(u21, self.characterReferenceCode);
                    const emitted = self.flushCodepointAsCharacterReference(codepoint);

                    self.state = self.returnState.?;
                    if (err != null) return err.?;
                    if (emitted) return self.popQueuedErrorOrToken();
                }
            }
        }

        unreachable;
    }

    pub fn eof(self: Self) bool {
        // if we're reconsuming, then we can still read the last character
        const max_index = if (self.reconsume) self.contents.len else self.contents.len - 1;
        return self.index > max_index;
    }

    fn popQueuedErrorOrToken(self: *Self) ParseError!?Token {
        // check errors first
        if (self.errorQueue.readItem()) |err_int| {
            return @errSetCast(ParseError, @intToError(err_int));
        }
        if (self.backlog.readItem()) |token| {
            return token;
        }
        return null;
    }

    pub fn emitToken(self: *Self, token: Token) void {
        if (token == .EndTag) {
            if (token.EndTag.attributes.items().len > 0) {
                self.errorQueue.writeItem(@errorToInt(ParseError.EndTagWithAttributes)) catch unreachable;
            }
            if (token.EndTag.selfClosing) {
                self.errorQueue.writeItem(@errorToInt(ParseError.EndTagWithTrailingSolidus)) catch unreachable;
            }
        }
        self.backlog.writeItem(token) catch unreachable;
    }

    fn inAttributeState(self: Self) bool {
        return switch (self.returnState.?) {
            .AttributeValueDoubleQuoted,
            .AttributeValueSingleQuoted,
            .AttributeValueUnquoted => true,
            else => false,
        };
    }

    /// Returns true if at least one token was emitted, false otherwise
    fn flushTemporaryBufferAsCharacterReference(self: *Self) bool {
        const characterReference = self.temporaryBuffer.toOwnedSlice();
        if (self.inAttributeState()) {
            self.currentAttributeValue.appendSlice(characterReference) catch unreachable;
            return false;
        } else {
            var i: usize = characterReference.len - 1;
            while (i >= 0) {
                self.emitToken(Token { .Character = .{ .data = characterReference[i] } });
                if (i == 0) break;
                i -= 1;
            }
            return true;
        }
    }

    /// Returns true if at least one token was emitted, false otherwise
    fn flushCodepointAsCharacterReference(self: *Self, codepoint: u21) bool {
        if (self.inAttributeState()) {
            var char: [4]u8 = undefined;
            var len = std.unicode.utf8Encode(codepoint, char[0..]) catch unreachable;
            self.temporaryBuffer.appendSlice(char[0..len]) catch unreachable;
            self.currentAttributeValue.appendSlice(self.temporaryBuffer.toOwnedSlice()) catch unreachable;
            return false;
        } else {
            self.temporaryBuffer.shrink(0);
            self.emitToken(Token { .Character = .{ .data = codepoint } });
            return true;
        }
    }

    fn addAttributeToCurrentToken(self: *Self) void {
        if (self.currentAttributeName.items.len < 1) return;
        var name = self.currentAttributeName.toOwnedSlice();
        var value = self.currentAttributeValue.toOwnedSlice();
        switch (self.currentToken.?) {
            .StartTag => |*tag| {
                _ = tag.attributes.put(name, value) catch unreachable;
                tag.name = self.tokenData.toOwnedSlice();
            },
            .EndTag => |*tag| {
                _= tag.attributes.put(name, value) catch unreachable;
                tag.name = self.tokenData.toOwnedSlice();
            },
            else => {}
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
};
