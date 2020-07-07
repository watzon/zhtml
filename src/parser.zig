const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const node = @import("node.zig");

const Document = node.Document;
const Element = node.Element;

const Token = @import("token.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const ParseError = @import("parse_error.zig").ParseError;

pub const Parser = struct {
    const Self = @This();

    /// The insertion mode is a state variable that controls the primary operation of the tree construction stage.
    /// https://html.spec.whatwg.org/multipage/parsing.html#the-insertion-mode
    pub const InsertionMode = enum {
        Initial,
        BeforeHtml,
        BeforeHead,
        InHead,
        InHeadNoscript,
        AfterHead,
        InBody,
        Text,
        InTable,
        InTableText,
        InCaption,
        InColumnGroup,
        InTableBody,
        InRow,
        InCell,
        InSelect,
        InSelectInTable,
        InTemplate,
        AfterBody,
        InFrameset,
        AfterFrameset,
        AfterAfterBody,
        AfterAfterFrameset,
    };

    allocator: *mem.Allocator,
    tokenizer: *Tokenizer,
    stackOfOpenElements: ArrayList(Element),
    insertionMode: InsertionMode,
    reprocess: bool = false,
    lastToken: Token = undefined,
    context: ?Element = null,

    pub fn init(allocator: *mem.Allocator, tokenizer: *Tokenizer) Parser {
        var stackOfOpenElements = ArrayList(Element).init(allocator);
        return Parser {
            .allocator = allocator,
            .tokenizer = tokenizer,
            .stackOfOpenElements = stackOfOpenElements,
            .insertionMode = .Initial,
        };
    }

    pub fn adjustedCurrentNode(self: *Self) Element {
        // The adjusted current node is the context element if the parser was created as part of the HTML fragment
        // parsing algorithm and the stack of open elements has only one element in it (fragment case); otherwise,
        // the adjusted current node is the current node.
        
        if (self.context) |ctx| {
            if (self.stackOfOpenElements.items.len == 1) {
                return ctx;
            }
        }

        var elementStack = self.stackOfOpenElements.items;
        return elementStack[elementStack.len - 1];
    }

    pub fn parse(self: *Self) !Document {
        var document = Document.init(self.allocator);
        while (true) {
            var token: ?Token = null;
            if (self.reprocess) {
                token = self.lastToken;
            } else {
                token = self.tokenizer.nextToken() catch |err| {
                    document.parseErrors.append(err) catch unreachable;
                    continue;
                };
            }

            if (token) |tok| {
                self.lastToken = tok;

                if (// If the stack of open elements is empty
                    (self.stackOfOpenElements.items.len == 0) or

                    // If the adjusted current node is an element in the HTML namespace
                    (self.adjustedCurrentNode().isInNamespace(.HTML)) or

                    // If the adjusted current node is a MathML text integration point and the token is a start tag
                    // whose tag name is neither "mglyph" nor "malignmark"
                    (self.adjustedCurrentNode().isMathMLTextIntegrationPoint() and
                        tok == Token.StartTag and
                        (mem.eql(u8, tok.StartTag.name.?, "mglyph")
                            or (mem.eql(u8, tok.StartTag.name.?, "malignmark")))) or

                    // If the adjusted current node is a MathML text integration point and the token is a character token
                    (self.adjustedCurrentNode().isMathMLTextIntegrationPoint() and
                        tok == Token.Character) or
                    
                    // If the adjusted current node is a MathML annotation-xml element and the token is a start tag whose tag name is "svg"
                    (mem.eql(u8, self.adjustedCurrentNode().name, "annotation-xml") and
                        tok == Token.StartTag and
                        mem.eql(u8, tok.StartTag.name.?, "svg")) or

                    // If the adjusted current node is an HTML integration point and the token is a start tag
                    (self.adjustedCurrentNode().isHTMLIntegrationPoint() and tok == Token.StartTag) or

                    // If the adjusted current node is an HTML integration point and the token is a character token
                    (self.adjustedCurrentNode().isHTMLIntegrationPoint() and tok == Token.Character) or
                    
                    // If the token is an end-of-file token
                    (tok == Token.EndOfFile)) {
                    switch (self.insertionMode) {
                        .Initial => {
                            self.handleInitialInsertionMode(&document, tok);
                        },
                        .BeforeHtml => {
                            self.handleBeforeHtmlInsertionMode(&document, tok);
                        },
                        else => {
                            std.debug.warn("{}\n", .{ self.insertionMode });
                            break;
                        }
                    }
                } else {
                    // TODO: Process the token according to the rules given in the section for parsing tokens in foreign content.
                    unreachable;
                }
            }
        }
        return document;
    }

    // pub fn parseFragment(self: *Self, input: []const u8) !Document { }

    fn handleInitialInsertionMode(self: *Self, document: *Document, token: Token) void {
        switch (token) {
            Token.Character => |tok| {
                if (tok.data == '\t' or tok.data == ' ' or tok.data == 0x000A or
                    tok.data == 0x000C or tok.data == 0x000D) {
                    // Ignore and do nothing
                    return;
                }
            },
            Token.Comment => |tok| {
                document.appendNode(node.Node { .Comment = .{ .data = tok.data.? } });
                return;
            },
            Token.DOCTYPE => |tok| {
                if ((tok.name != null and !mem.eql(u8, tok.name.?, "html")) or
                    (tok.publicIdentifier != null and tok.publicIdentifier.?.len != 0) or
                    (tok.systemIdentifier != null and !mem.eql(u8, tok.systemIdentifier.?, "about:legacy-compat"))) {
                    document.parseErrors.append(ParseError.Default) catch unreachable;
                }

                var doctype = node.DocumentType {
                    .name = if (tok.name == null) "" else tok.name.?,
                    .publicId = if (tok.publicIdentifier == null) "" else tok.publicIdentifier.?,
                    .systemId = if (tok.systemIdentifier == null) "" else tok.systemIdentifier.?,
                };

                document.appendNode(node.Node { .DocumentType = doctype });
                document.doctype = doctype;

                if (tok.forceQuirks or
                    mem.eql(u8, doctype.publicId, "-//W3O//DTD W3 HTML Strict 3.0//EN//") or
                    mem.eql(u8, doctype.publicId, "-/W3C/DTD HTML 4.0 Transitional/EN") or
                    mem.eql(u8, doctype.publicId, "HTML") or
                    mem.eql(u8, doctype.systemId, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd") or
                    mem.startsWith(u8, doctype.publicId, "+//Silmaril//dtd html Pro v0r11 19970101//") or
                    mem.startsWith(u8, doctype.publicId, "-//AS//DTD HTML 3.0 asWedit + extensions//") or
                    mem.startsWith(u8, doctype.publicId, "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.0 Level 1//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.0 Level 2//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.0 Strict Level 1//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.0 Strict Level 2//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.0 Strict//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 2.1E//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 3.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 3.2 Final//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 3.2//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML 3//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Level 0//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Level 1//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Level 2//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Level 3//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Strict Level 0//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Strict Level 1//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Strict Level 2//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Strict Level 3//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML Strict//") or
                    mem.startsWith(u8, doctype.publicId, "-//IETF//DTD HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//Metrius//DTD Metrius Presentational//") or
                    mem.startsWith(u8, doctype.publicId, "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//") or
                    mem.startsWith(u8, doctype.publicId, "-//Microsoft//DTD Internet Explorer 2.0 HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//Microsoft//DTD Internet Explorer 2.0 Tables//") or
                    mem.startsWith(u8, doctype.publicId, "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//") or
                    mem.startsWith(u8, doctype.publicId, "-//Microsoft//DTD Internet Explorer 3.0 HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//Microsoft//DTD Internet Explorer 3.0 Tables//") or
                    mem.startsWith(u8, doctype.publicId, "-//Netscape Comm. Corp.//DTD HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//Netscape Comm. Corp.//DTD Strict HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//O'Reilly and Associates//DTD HTML 2.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//O'Reilly and Associates//DTD HTML Extended 1.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//") or
                    mem.startsWith(u8, doctype.publicId, "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//Spyglass//DTD HTML 2.0 Extended//") or
                    mem.startsWith(u8, doctype.publicId, "-//Sun Microsystems Corp.//DTD HotJava HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 3 1995-03-24//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 3.2 Draft//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 3.2 Final//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 3.2//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 3.2S Draft//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 4.0 Frameset//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML 4.0 Transitional//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML Experimental 19960712//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD HTML Experimental 970421//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3C//DTD W3 HTML//") or
                    mem.startsWith(u8, doctype.publicId, "-//W3O//DTD W3 HTML 3.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//WebTechs//DTD Mozilla HTML 2.0//") or
                    mem.startsWith(u8, doctype.publicId, "-//WebTechs//DTD Mozilla HTML//") or
                    mem.startsWith(u8, doctype.systemId, "-//W3C//DTD HTML 4.01 Frameset//") or
                    mem.startsWith(u8, doctype.systemId, "-//W3C//DTD HTML 4.01 Transitional//")) {
                    document.quirksMode = true;
                    return;
                } else if (mem.startsWith(u8, doctype.publicId, "-//W3C//DTD XHTML 1.0 Frameset//") or
                           mem.startsWith(u8, doctype.publicId, "-//W3C//DTD XHTML 1.0 Transitional//") or
                           (doctype.systemId.len != 0 and mem.startsWith(u8, doctype.systemId, "-//W3C//DTD HTML 4.01 Frameset//")) or
                           (doctype.systemId.len != 0 and mem.startsWith(u8, doctype.systemId, "-//W3C//DTD HTML 4.01 Transitional//"))) {
                    self.insertionMode = .BeforeHtml;
                    return;
                }
            },
            else => {}
        }

        self.reprocess = true;
        self.insertionMode = .BeforeHtml;
        document.quirksMode = true;
        document.parseErrors.append(ParseError.Default) catch unreachable;
    }

    fn handleBeforeHtmlInsertionMode(self: *Self, document: *Document, token: Token) void {
        switch (token) {
            Token.DOCTYPE => {
                document.parseErrors.append(ParseError.Default) catch unreachable;
                return;
            },
            Token.Comment => |tok| {
                document.appendNode(node.Node { .Comment = .{ .data = tok.data.? } });
                return;
            },
            Token.Character => |tok| {
                if (tok.data == '\t' or tok.data == ' ' or tok.data == 0x000A or
                    tok.data == 0x000C or tok.data == 0x000D) {
                    // Ignore and do nothing
                    return;
                }
            },
            Token.StartTag => |tok| {
                if (mem.eql(u8, tok.name.?, "html")) {
                    var element = self.createElementForToken(document, token);
                }
            },
            else => {}
        }
    }

    fn createElementForToken(self: Self, document: *Document, token: Token) Element {
        var local_name = token.StartTag.name.?;
        var is = token.StartTag.attributes.get("is");
        var definition: ?Element = null; // TODO: Look up custom element definition

        var will_execute_script = definition != null and self.context == null;
        if (will_execute_script) {
            // will execute script
            document.throwOnDynamicMarkupInsertionCounter += 1;
            // TODO: If the JavaScript execution context stack is empty, then perform a microtask checkpoint.
            // TODO: Push a new element queue onto document's relevant agent's custom element reactions stack.
        }

        var element = Element.init();
    }
};