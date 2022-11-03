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

        pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try writer.print(".name = {any}, .selfClosing = {any}", .{ value.name, value.selfClosing });
            var it = value.attributes.iterator();
            if (value.attributes.count() > 0) {
                try writer.writeAll(", attributes = .{ ");
                var i: u32 = 0;
                while (it.next()) |entry| {
                    try writer.print("{s}: \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                    if (i + 1 < value.attributes.count())
                        try writer.writeAll(", ");
                }
                try writer.writeAll(" }");
                i += 1;
            }
            try writer.writeAll(" }");
        }
    },
    EndTag: struct {
        name: ?[]const u8 = null,
        /// Ignored past tokenization, only used for errors
        selfClosing: bool = false,
        /// Ignored past tokenization, only used for errors
        attributes: StringHashMap([]const u8),

        pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try writer.print(".name = {any}, .selfClosing = {any}", .{ value.name, value.selfClosing });
            try writer.writeAll(" }");
        }
    },
    Comment: struct {
        data: ?[]const u8 = null,
    },
    Character: struct {
        data: u21,

        pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            var char: [4]u8 = undefined;
            var len = std.unicode.utf8Encode(value.data, char[0..]) catch unreachable;
            if (char[0] == '\n') {
                len = 2;
                std.mem.copy(u8, char[0..2], "\\n");
            }
            try writer.print("\"{s}\"", .{ char[0..len] });
        }
    },
    EndOfFile,
};
