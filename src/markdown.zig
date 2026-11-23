const std = @import("std");
const term = @import("terminal.zig");
const inline_md = @import("inline.zig");
const renderInline = inline_md.render;
const writeText = inline_md.writeText;
const Tables = @import("table.zig").Tables;
const heading = @import("heading.zig");
const assert = std.debug.assert;
pub const line_max = 64 * 1024;
pub const document_max = 8 * 1024 * 1024;

comptime {
    assert(line_max < document_max);
    assert(document_max < std.math.maxInt(u32));
}

pub fn render(input: anytype, output: anytype, line_number: *u32) !void {
    try renderStyled(input, output, line_number, .{});
}

pub fn renderStyled(input: anytype, output: anytype, line_number: *u32, options: term.Style) !void {
    var style = options;
    var chunk: [8192]u8 = undefined;
    var line: [line_max]u8 = undefined;
    var used: u32 = 0;
    var total: u32 = 0;
    var blocks: Blocks = .{};
    defer if (blocks.graphics) |workspace| std.heap.page_allocator.destroy(workspace);
    line_number.* = 1;
    while (total <= document_max) {
        const count = try input.read(chunk[0..@min(chunk.len, document_max - total + 1)]);
        if (count == 0) break;
        for (chunk[0..count]) |byte| {
            if (total == document_max) {
                try blocks.finish(&style, output);
                return error.DocumentLimit;
            }
            total += 1;
            if (byte == '\n') {
                const end = if (used > 0 and line[used - 1] == '\r') used - 1 else used;
                try blocks.line(line[0..end], true, &style, output);
                used = 0;
                line_number.* += 1;
            } else {
                if (used == line_max) {
                    try blocks.finish(&style, output);
                    return error.LineLimit;
                }
                line[used] = byte;
                used += 1;
            }
            assert(used <= line_max);
        }
    }
    assert(total <= document_max);
    if (used > 0) try blocks.line(line[0..used], false, &style, output);
    try blocks.finish(&style, output);
}

fn validate(line: []const u8) !void {
    assert(line.len <= line_max);
    const view = std.unicode.Utf8View.init(line) catch return error.Encoding;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| switch (cp) {
        '\t' => {},
        0...8, 10...31, 127...159, 0x061c, 0x200e...0x200f, 0x202a...0x202e, 0x2066...0x2069 => return error.Control,
        else => {},
    };
    assert(iter.i == line.len);
}

const Fence = struct {
    char: u8 = 0,
    length: usize = 0,

    fn consume(self: *Fence, line: []const u8) bool {
        const s = std.mem.trimLeft(u8, line, " ");
        if (line.len - s.len > 3 or s.len < 3) return false;
        if (s[0] != 96 and s[0] != '~') return false;
        const n = runLength(s, s[0]);
        if (n < 3) return false;
        if (self.length == 0) {
            if (s[0] == 96 and std.mem.indexOfScalar(u8, s[n..], 96) != null) return false;
            self.* = .{ .char = s[0], .length = n };
        } else {
            if (s[0] != self.char or n < self.length) return false;
            if (std.mem.trim(u8, s[n..], " \t").len != 0) return false;
            self.* = .{};
        }
        return true;
    }
};

fn runLength(s: []const u8, ch: u8) usize {
    for (s, 0..) |byte, i| if (byte != ch) return i;
    return s.len;
}

const Block = union(enum) {
    paragraph,
    heading: struct { level: usize, title: []const u8 },
    bullet: []const u8,
    quote: []const u8,
    numbered,
};

fn isSeparator(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn classify(s: []const u8) Block {
    const hashes = runLength(s, '#');
    if (hashes > 0 and hashes <= 6 and (hashes == s.len or isSeparator(s[hashes]))) {
        var title = std.mem.trim(u8, s[hashes..], " \t");
        const before_hashes = std.mem.trimRight(u8, title, "#");
        if (before_hashes.len < title.len and (before_hashes.len == 0 or isSeparator(before_hashes[before_hashes.len - 1]))) {
            title = std.mem.trimRight(u8, before_hashes, " \t");
        }
        return .{ .heading = .{ .level = hashes, .title = title } };
    }
    if (s.len >= 2 and isSeparator(s[1]) and std.mem.indexOfScalar(u8, "-+*", s[0]) != null)
        return .{ .bullet = s[2..] };
    if (std.mem.startsWith(u8, s, ">")) {
        const start: usize = if (std.mem.startsWith(u8, s, "> ")) 2 else 1;
        return .{ .quote = s[start..] };
    }

    var digits: usize = 0;
    while (digits < @min(9, s.len) and std.ascii.isDigit(s[digits])) digits += 1;
    if (digits != 0 and digits + 1 < s.len and (s[digits] == '.' or s[digits] == ')') and isSeparator(s[digits + 1]))
        return .numbered;
    return .paragraph;
}

fn renderHeading(title: []const u8, level: usize, indent: usize, workspace: *?*heading.Workspace, style: *term.Style, out: anytype) !void {
    if (style.graphics and level <= 3 and style.pixels_left > 0 and title.len <= 2048) {
        var buf: [16384]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        if (level == 3) try stream.writer().writeAll(term.h3_prefix);
        try renderInline(title, .neutral, stream.writer());
        if (try heading.display(workspace, stream.getWritten(), level, indent, style, out)) return;
    }
    if (style.colors) try out.writeAll(if (level == 3) term.h3_gray ++ term.h3_prefix ++ term.orange_red else term.red);
    try renderInline(title, style.inlineStyle(), out);
    if (style.colors) try out.writeAll(term.foreground_end);
}

fn codeLine(bytes: []const u8, styled: bool, out: anytype) !void {
    if (styled) try out.writeAll(term.block ++ "│ ");
    try writeText(out, bytes);
    if (styled) try out.writeAll(term.foreground_end);
}

// Consume exactly one indentation level. A tab advances to the fourth column.
fn codeIndent(bytes: []const u8) usize {
    for (bytes[0..@min(bytes.len, 4)], 0..) |byte, i| {
        if (byte == '\t') return i + 1;
        if (byte != ' ') break;
        if (i == 3) return 4;
    }
    return 0;
}

const Blocks = struct {
    fence: Fence = .{},
    table: Tables = .{},
    may_indent: bool = true,
    graphics: ?*heading.Workspace = null,

    fn line(self: *Blocks, bytes: []const u8, newline: bool, style: *term.Style, out: anytype) !void {
        validate(bytes) catch |err| {
            try self.finish(style, out);
            return err;
        };
        const indent = codeIndent(bytes);
        if (self.fence.length == 0 and self.may_indent and indent > 0) {
            try self.finish(style, out);
            try codeLine(bytes[indent..], style.colors, out);
            if (newline) try out.writeByte('\n');
            return;
        }
        self.may_indent = std.mem.trim(u8, bytes, " \t").len == 0;
        if (self.fence.consume(bytes)) {
            try self.finish(style, out);
            return;
        }
        if (self.fence.length != 0) {
            try codeLine(bytes, style.colors, out);
        } else {
            const spaces = runLength(bytes, ' ');
            const body = bytes[spaces..];
            const block: Block = if (indent == 0) classify(body) else .paragraph;
            const table_candidate = indent == 0 and block == .paragraph;
            if (table_candidate and try self.table.append(bytes, newline, style.inlineStyle(), out)) return;
            try self.finish(style, out);
            if (table_candidate and self.table.begin(bytes, newline)) return;

            try out.writeAll(bytes[0..spaces]);
            switch (block) {
                .heading => |h| try renderHeading(h.title, h.level, spaces, &self.graphics, style, out),
                .bullet => |text| {
                    try out.writeAll("• ");
                    try renderInline(text, style.inlineStyle(), out);
                },
                .quote => |text| {
                    try out.writeAll("│ ");
                    try renderInline(text, style.inlineStyle(), out);
                },
                .paragraph, .numbered => try renderInline(body, style.inlineStyle(), out),
            }
        }
        if (newline) try out.writeByte('\n');
    }

    fn finish(self: *Blocks, style: *term.Style, out: anytype) !void {
        if (self.table.active) {
            try self.table.flush(style.inlineStyle(), out);
        } else if (self.table.used != 0) {
            try renderInline(self.table.data[0..self.table.used], style.inlineStyle(), out);
            if (self.table.newline) try out.writeByte('\n');
        }
        self.table.reset();
    }
};
