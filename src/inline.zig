const std = @import("std");
const term = @import("terminal.zig");
const isWord = @import("unicode_properties.zig").isWord;
const assert = std.debug.assert;

pub fn writeText(out: anytype, s: []const u8) !void {
    var parts = std.mem.splitScalar(u8, s, '\t');
    try out.writeAll(parts.first());
    while (parts.next()) |part| {
        try out.writeAll("    ");
        try out.writeAll(part);
    }
}

// Each delimiter has a forward-only search cursor. Failed matches, including
// missing link terminators, cost at most one scan per delimiter per line.
const Search = struct {
    position: usize = 0,

    fn next(self: *Search, s: []const u8, start: usize, needle: []const u8) ?usize {
        assert(start <= s.len);
        assert(self.position <= s.len);
        const from = @max(start, self.position);
        self.position = std.mem.indexOfPos(u8, s, from, needle) orelse s.len;
        return if (self.position < s.len) self.position else null;
    }
};

fn joinsWord(s: []const u8, at: usize, len: usize) bool {
    assert(len > 0);
    assert(at + len <= s.len);
    if (at == 0 or at + len == s.len) return false;
    // Lines have already passed UTF-8 validation. Back up to the leading
    // byte of the preceding code point before decoding either neighbor.
    var prev = at - 1;
    while (s[prev] & 0xc0 == 0x80) prev -= 1;
    const left = std.unicode.utf8Decode(s[prev..at]) catch unreachable;
    var right = std.unicode.Utf8View.initUnchecked(s[at + len ..]).iterator();
    return isWord(left) and isWord(right.nextCodepoint().?);
}

fn closingMarker(search: *Search, s: []const u8, body: usize, marker: []const u8) ?usize {
    var start = body;
    while (search.next(s, start, marker)) |end| {
        assert(end >= body);
        assert(end > 0);
        const in_word = marker[0] == '_' and joinsWord(s, end, marker.len);
        if (!in_word and !std.ascii.isWhitespace(s[end - 1])) return end;
        start = end + marker.len;
    }
    return null;
}

fn tickCount(s: []const u8) usize {
    for (s, 0..) |byte, i| if (byte != 96) return i;
    return s.len;
}

fn findTicks(search: *Search, s: []const u8, from: usize, count: usize) ?usize {
    var start = from;
    while (search.next(s, start, "`")) |at| {
        const size = tickCount(s[at..]);
        if (size == count) return at;
        start = at + size;
    }
    return null;
}

fn writeCode(out: anytype, raw: []const u8, styled: term.InlineStyle) !void {
    var code = raw;
    if (code.len >= 2 and code[0] == ' ' and code[code.len - 1] == ' ' and
        std.mem.trim(u8, code, " ").len != 0) code = code[1 .. code.len - 1];
    try out.writeAll(styled.code());
    try writeText(out, code);
    try out.writeAll(styled.codeEnd());
}

const Links = struct {
    bracket: Search = .{},
    nested: Search = .{},
    paren: Search = .{},

    fn match(self: *Links, s: []const u8, label: usize) ?struct { bracket: usize, end: usize } {
        const b = self.bracket.next(s, label, "]") orelse return null;
        if ((self.nested.next(s, label, "[") orelse s.len) < b) return null;
        if (!std.mem.startsWith(u8, s[b..], "](")) return null;
        const end = self.paren.next(s, b + 2, ")") orelse return null;
        return .{ .bracket = b, .end = end };
    }
};

pub fn render(s: []const u8, styled: term.InlineStyle, out: anytype) !void {
    const markers = [_][]const u8{ "**", "__", "*", "_" };
    var ticks = [_]Search{.{}} ** 32;
    var closes = [_]Search{.{}} ** markers.len;
    var links: Links = .{};
    var i: usize = 0;
    var literal: usize = 0;
    while (i < s.len) {
        assert(literal <= i);
        if (s[i] == 96) {
            const n = tickCount(s[i..]);
            const body = i + n;
            i = body;
            if (n <= ticks.len) {
                if (findTicks(&ticks[n - 1], s, body, n)) |end| {
                    try writeText(out, s[literal .. body - n]);
                    try writeCode(out, s[body..end], styled);
                    i = end + n;
                    literal = i;
                }
            }
            continue;
        }
        const image = std.mem.startsWith(u8, s[i..], "![");
        if (image or s[i] == '[') {
            const label = i + @as(usize, if (image) 2 else 1);
            if (links.match(s, label)) |link| {
                try writeText(out, s[literal..i]);
                if (styled != .plain and !image) try out.writeAll(term.underline);
                try writeText(out, s[label..link.bracket]);
                if (styled != .plain and !image) try out.writeAll(term.underline_end);
                i = link.end + 1;
                literal = i;
                continue;
            }
        }
        var matched = false;
        for (markers, 0..) |marker, k| {
            if (!std.mem.startsWith(u8, s[i..], marker)) continue;
            const body = i + marker.len;
            const in_word = marker[0] == '_' and joinsWord(s, i, marker.len);
            const blank = body == s.len or std.ascii.isWhitespace(s[body]);
            if (blank or in_word) {
                i = body;
                break;
            }
            if (closingMarker(&closes[k], s, body, marker)) |end| {
                if (end > body) {
                    try writeText(out, s[literal..i]);
                    const on = if (marker.len == 2) term.bold else "";
                    const off = if (marker.len == 2) term.bold_end else "";
                    if (styled != .plain) try out.writeAll(on);
                    try writeText(out, s[body..end]);
                    if (styled != .plain) try out.writeAll(off);
                    i = end + marker.len;
                    literal = i;
                    matched = true;
                }
            }
            if (!matched) i = body;
            break;
        } else {
            i += 1;
        }
        assert(i <= s.len);
    }
    try writeText(out, s[literal..]);
}
