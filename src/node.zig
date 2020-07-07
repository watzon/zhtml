const std = @import("std");
const Token = @import("token.zig").Token;
const ArrayList = std.ArrayList;
const StringHashMap = std.hash_map.StringHashMap;
const ParseError = @import("parse_error.zig").ParseError;

pub const Node = union(enum) {
    Document: Document,
    DocumentType: DocumentType,
    DocumentFragment: DocumentFragment,
    Element: Element,
    Text: Text,
    ProcessingInstruction: ProcessingInstruction,
    Comment: Comment,
};

pub const Document = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    title: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    quirksMode: bool = false,
    limitedQuirksMode: bool = false,
    doctype: ?DocumentType = null,
    body: ?Element = null,
    head: ?Element = null,
    images: ArrayList(Element),
    embeds: ArrayList(Element),
    plugins: ArrayList(Element),
    links: ArrayList(Element),
    forms: ArrayList(Element),
    scripts: ArrayList(Element),
    parseErrors: ArrayList(ParseError),
    currentScript: ?Element = null,
    children: ArrayList(Node),
    throwOnDynamicMarkupInsertionCounter: usize = 0,

    pub fn init(allocator: *std.mem.Allocator) Document {
        return Document{
            .allocator = allocator,
            .images = ArrayList(Element).init(allocator),
            .embeds = ArrayList(Element).init(allocator),
            .plugins = ArrayList(Element).init(allocator),
            .links = ArrayList(Element).init(allocator),
            .forms = ArrayList(Element).init(allocator),
            .scripts = ArrayList(Element).init(allocator),
            .children = ArrayList(Node).init(allocator),
            .parseErrors = ArrayList(ParseError).init(allocator),
        };
    }

    pub fn appendNode(self: *Self, node: Node) void {
        self.children.append(node) catch unreachable;
    }

    pub fn nodeCount(self: Self) usize {
        return self.children.items.len;
    }

    pub fn popNode(self: *Self) ?Node {
        return self.children.popOrNull();
    }
};

pub const DocumentType = struct {
    const Self = @This();

    name: []const u8,
    publicId: []const u8,
    systemId: []const u8,
};

pub const DocumentFragment = struct {
    const Self = @This();
};

pub const Element = struct {
    const Self = @This();

    const Namespace = enum {
        HTML,
        MathML,
        SVG,
        XLink,
        XML,
        XMLNS,

        pub fn toUri(self: Namespace) []const u8 {
            return switch (self) {
                .HTML => "http://www.w3.org/1999/xhtml",
                .MathML => "http://www.w3.org/1998/Math/MathML",
                .SVG => "http://www.w3.org/2000/svg",
                .XLink => "http://www.w3.org/1999/xlink",
                .XML => "http://www.w3.org/XML/1998/namespace",
                .XMLNS => "http://www.w3.org/2000/xmlns/",
            };
        }
    };

    namespace: Namespace,
    prefix: ?[]const u8,
    localName: []const u8,
    tagName: []const u8,

    id: []const u8,
    className: []const u8,
    classList: ArrayList([]const u8),
    slot: []const u8,

    document: Document,
    attributes: StringHashMap([]const u8),

    pub fn init(local_name: []const u8, document: Document, namespace: Namespace, token: ?Token) Element {
        var definition: ?Element = null; // TODO: Look up custom element definition

        return Element{
            .name = local_name,
            .document = document,
            .namespace = namespace,
            .attributes = attributes,
            .prefix = null,
            .is = null,
            .synchronousCustomElements = false,
        };
    }

    pub fn namespaceUri(self: Self) []const u8 {
        return self.namespace.toUri();
    }

    pub fn hasAttributes(self: Self) bool {
        return self.attributes.items().len > 0;
    }

    pub fn getAttributeNames(self: Self) [][]const u8 {}

    pub fn isInNamespace(self: Self, namespace: Namespace) bool {
        return self.namespace == namespace;
    }

    pub fn isHTMLIntegrationPoint(self: Self) bool {
        return false;
    }

    pub fn isMathMLTextIntegrationPoint(self: Self) bool {
        return false;
    }
};

pub const Text = struct {
    const Self = @This();
};

pub const ProcessingInstruction = struct {
    const Self = @This();
};

pub const Comment = struct {
    const Self = @This();

    data: []const u8
};
