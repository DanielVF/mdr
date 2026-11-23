const term = @import("terminal.zig");
const std = @import("std");
const inline_md = @import("inline.zig");

const column_max = 32;
const Align = enum { left, center, right };
const Cells = struct {
    values: [column_max][]const u8 = undefined,
    len: usize = 0,

    fn parse(bytes: []const u8) ?Cells {
        var s = std.mem.trim(u8, bytes, " \t");
        if (std.mem.indexOfScalar(u8, s, '|') == null) return null;
        const leading = s[0] == '|';
        if (leading) s = s[1..];
        var cells: Cells = .{};
        var start: usize = 0;
        var escaped = false;
        var divided = leading;
        for (s, 0..) |ch, i| {
            if (ch == '|' and !escaped) {
                if (!cells.push(s[start..i])) return null;
                start = i + 1;
                divided = true;
            }
            escaped = ch == '\\' and !escaped;
        }
        if (!divided) return null;
        if (start < s.len and !cells.push(s[start..])) return null;
        return if (cells.len > 0) cells else null;
    }

    fn push(self: *Cells, cell: []const u8) bool {
        if (self.len == column_max) return false;
        self.values[self.len] = std.mem.trim(u8, cell, " \t");
        self.len += 1;
        return true;
    }
};

fn alignment(cell: []const u8) ?Align {
    const left = std.mem.startsWith(u8, cell, ":");
    const right = std.mem.endsWith(u8, cell, ":");
    const skip: usize = @intFromBool(left);
    const tail: usize = @intFromBool(right);
    if (cell.len < skip + tail + 3) return null;
    for (cell[skip .. cell.len - tail]) |c| if (c != '-') return null;
    return if (right and left) .center else if (right) .right else .left;
}

fn renderCell(cell: []const u8, styled: term.InlineStyle, out: anytype) !void {
    if (std.mem.indexOf(u8, cell, "\\|") == null) return inline_md.render(cell, styled, out);
    var decoded: [65536]u8 = undefined;
    const n = std.mem.replacementSize(u8, cell, "\\|", "|");
    _ = std.mem.replace(u8, cell, "\\|", "|", decoded[0..n]);
    try inline_md.render(decoded[0..n], styled, out);
}

const Width = struct {
    measure: @import("cell_width.zig").Measure = .{},

    fn write(self: *Width, bytes: []const u8) error{}!usize {
        var iter = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        while (iter.nextCodepoint()) |cp| self.measure.add(cp);
        return bytes.len;
    }

    fn of(cell: []const u8) usize {
        var w: Width = .{};
        const writer = std.io.Writer(*Width, error{}, write){ .context = &w };
        renderCell(cell, .plain, writer) catch unreachable;
        return w.measure.cells();
    }
};

pub const Tables = struct {
    // Buffer a bounded batch to size columns before emitting it.
    padding_left: usize = 8 * 1024 * 1024,
    data: [65537]u8 = undefined,
    used: usize = 0,
    columns: usize = 0,
    active: bool = false,
    header: bool = false,
    newline: bool = false,
    widths: [column_max]usize = undefined,
    alignments: [column_max]Align = undefined,

    pub fn reset(self: *Tables) void {
        self.used = 0;
        self.columns = 0;
        self.active = false;
        self.header = false;
    }

    pub fn begin(self: *Tables, bytes: []const u8, newline: bool) bool {
        const cells = Cells.parse(bytes) orelse return false;
        self.columns = cells.len;
        self.used = bytes.len;
        self.newline = newline;
        @memcpy(self.data[0..bytes.len], bytes);
        return true;
    }

    pub fn append(self: *Tables, bytes: []const u8, newline: bool, styled: term.InlineStyle, out: anytype) !bool {
        if (self.columns == 0) return false;
        const cells = Cells.parse(bytes) orelse return false;
        if (cells.len > self.columns) return false;
        if (!self.active) {
            if (cells.len != self.columns) return false;
            for (cells.values[0..cells.len], 0..) |cell, i| {
                self.alignments[i] = alignment(cell) orelse return false;
            }
            self.header = true;
            self.active = true;
            @memset(self.widths[0..self.columns], 3);
            self.measure(Cells.parse(self.data[0..self.used]).?);
            self.data[self.used] = '\n';
            self.used += 1;
        } else {
            if (bytes.len + 1 > self.data.len - self.used) try self.flush(styled, out);
            @memcpy(self.data[self.used..][0..bytes.len], bytes);
            self.used += bytes.len;
            self.data[self.used] = '\n';
            self.used += 1;
            self.measure(cells);
        }
        self.newline = newline;
        return true;
    }

    fn measure(self: *Tables, cells: Cells) void {
        for (cells.values[0..cells.len], 0..) |cell, i| {
            self.widths[i] = @max(self.widths[i], Width.of(cell));
        }
    }

    fn row(self: *Tables, cells: Cells, styled: term.InlineStyle, out: anytype) !void {
        for (0..self.columns) |i| {
            if (i >= cells.len and self.padding_left < 5) break;
            if (i >= cells.len) self.padding_left -= 5;
            const cell = if (i < cells.len) cells.values[i] else "";
            const pad = @min(80, self.padding_left, self.widths[i] -| Width.of(cell));
            self.padding_left -= pad;
            const before = switch (self.alignments[i]) {
                .left => 0,
                .center => pad / 2,
                .right => pad,
            };
            if (i > 0) try out.writeAll(" │ ");
            try out.writeByteNTimes(' ', before);
            try renderCell(cell, styled, out);
            try out.writeByteNTimes(' ', pad - before);
        }
    }

    pub fn flush(self: *Tables, styled: term.InlineStyle, out: anytype) !void {
        var rows = std.mem.tokenizeScalar(u8, self.data[0..self.used], '\n');
        while (rows.next()) |bytes| {
            try self.row(Cells.parse(bytes).?, styled, out);
            if (self.header) {
                try out.writeByte('\n');
                for (self.widths[0..self.columns], 0..) |width, i| {
                    if (i > 0) try out.writeAll("─┼─");
                    for (0..width) |_| try out.writeAll("─");
                }
                self.header = false;
            }
            if (rows.peek() != null or self.newline) try out.writeByte('\n');
        }
        self.used = 0;
    }
};
