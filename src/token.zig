const std = @import("std");
const mem = std.mem;
const StringHashMap = std.hash_map.StringHashMap;
const ArrayList = std.ArrayList;

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
        attributes: StringHashMap([]const u8),

        pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: var) !void {
            try writer.writeAll("{ ");
            try writer.print(".name = {}, .selfClosing = {}", .{ value.name, value.selfClosing });
            if (value.attributes.items().len > 0) {
                try writer.writeAll(", attributes = .{ ");
                for (value.attributes.items()) |entry, i| {
                    try writer.print("{}: \"{}\"", .{ entry.key, entry.value });
                    if (i + 1 < value.attributes.items().len)
                        try writer.writeAll(", ");
                }
                try writer.writeAll(" }");
            }
            try writer.writeAll(" }");
        }
    },
    EndTag: struct {
        name: ?[]const u8 = null,
        selfClosing: bool = false,
        attributes: StringHashMap([]const u8),

        pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: var) !void {
            try writer.writeAll("{ ");
            try writer.print(".name = {}, .selfClosing = {}", .{ value.name, value.selfClosing });
            try writer.writeAll(" }");
        }
    },
    Comment: struct {
        data: ?[]const u8 = null,
    },
    Character: struct {
        data: u21,

        pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: var) !void {
            var char: [4]u8 = undefined;
            var len = std.unicode.utf8Encode(value.data, char[0..]) catch unreachable;
            if (char[0] == '\n') {
                len = 2;
                std.mem.copy(u8, char[0..2], "\\n");
            }
            try writer.print("\"{}\"", .{ char[0..len] });
        }
    },

    pub const Attribute = struct {
        name:  []const u8,
        value: []const u8,
    };
};