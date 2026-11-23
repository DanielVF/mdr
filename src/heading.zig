const std = @import("std");
const term = @import("terminal.zig");
const assert = std.debug.assert;

const metrics = @embedFile("fonts/metrics.bin");
const coverage = @embedFile("fonts/coverage.bin");
const kerning = @embedFile("fonts/kerning.bin");
pub export const mdr_font_license = @embedFile("fonts/OFL.txt").*;
const width_max = 1600;
// Anchor every title to the same font baseline, including titles without descenders.
const height = 90;
// Additional leading keeps H3 smaller inside the same two-row box as H2.
const h3_above = 13;
const h3_below = 3;
const height_max = height + h3_above + h3_below;
const baseline = 69;
const placements_max = 256;

fn glyphIndex(cp: u21) ?usize {
    return switch (cp) {
        32...126 => cp - 32,
        160...383 => 95 + @as(usize, cp) - 160,
        0x370...0x52f => 319 + @as(usize, cp) - 0x370,
        0x2000...0x203f => 767 + @as(usize, cp) - 0x2000,
        else => null,
    };
}

const Glyph = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    offset: usize,
    bold: bool,
    code: bool,
    advance_end: usize,
    underline_start: usize,
    underline_end: usize,
};

const Face = struct {
    bold: bool = false,
    code: bool = false,
    underline: bool = false,

    fn control(self: *Face, text: []const u8) usize {
        const controls = .{
            .{ term.bold, &self.bold, true },                       .{ term.bold_end, &self.bold, false },
            .{ term.InlineStyle.neutral.code(), &self.code, true }, .{ term.InlineStyle.neutral.codeEnd(), &self.code, false },
            .{ term.underline, &self.underline, true },             .{ term.underline_end, &self.underline, false },
        };
        inline for (controls) |entry| {
            if (std.mem.startsWith(u8, text, entry[0])) {
                entry[1].* = entry[2];
                return entry[0].len;
            }
        }
        return 0;
    }
};

const Layout = struct {
    glyphs: [placements_max]Glyph = undefined,
    count: usize = 0,
    width: usize = 0,

    fn measure(self: *Layout, text: []const u8) bool {
        var i: usize = 0;
        var pen: i32 = 4 * 64;
        var previous: u21 = 0;
        var face: Face = .{};
        while (i < text.len) {
            if (text[i] == 0x1b) {
                const consumed = face.control(text[i..]);
                if (consumed == 0) return false;
                i += consumed;
                continue;
            }
            const length = std.unicode.utf8ByteSequenceLength(text[i]) catch unreachable;
            const cp = std.unicode.utf8Decode(text[i..][0..length]) catch unreachable;
            i += length;
            const index = glyphIndex(cp) orelse return false;
            const m = metrics[index * 10 ..][0..10];
            const advance = std.mem.readInt(u16, m[4..6], .little);
            if (advance == 0 or self.count == placements_max) return false;
            if (previous >= 32 and previous < 127 and cp >= 32 and cp < 127) {
                const k = ((previous - 32) * 95 + cp - 32) * 2;
                pen += std.mem.readInt(i16, kerning[k..][0..2], .little);
            }
            previous = cp;
            const origin = @divFloor(pen + 32, 64);
            const left = origin + @as(i32, @as(i8, @bitCast(m[6])));
            const top = baseline + @as(i32, @as(i8, @bitCast(m[7])));
            pen += advance;
            const end = @divFloor(pen + 32, 64);
            const right = @max(end, left + m[8]) + 4;
            if (left < 0 or origin < 0 or top < 0 or top + m[9] > height or right > width_max) return false;
            self.glyphs[self.count] = .{
                .x = @intCast(left),
                .y = @intCast(top),
                .w = m[8],
                .h = m[9],
                .offset = std.mem.readInt(u32, m[0..4], .little),
                .bold = face.bold,
                .code = face.code,
                .advance_end = @intCast(end),
                .underline_start = @intCast(origin),
                .underline_end = if (face.underline) @intCast(end) else 0,
            };
            self.count += 1;
            self.width = @max(self.width, @as(usize, @intCast(right)));
        }
        return self.count > 0;
    }

    fn paint(self: *const Layout, pixels: []u8, level: usize) void {
        assert(self.width <= width_max);
        assert(pixels.len == self.width * height * 4);
        @memset(pixels, 0);
        for (self.glyphs[0..self.count], 0..) |g, i| {
            const color: [3]u8 = if (level != 3)
                .{ 215, 95, 95 }
            else if (i < term.h3_prefix.len)
                .{ 98, 98, 98 }
            else
                .{ 212, 102, 56 }; // H2 lightness and chroma at a warmer OKLCH hue.
            if (g.code) {
                for (baseline - 43..baseline + 12) |y| {
                    for (g.underline_start..g.advance_end) |x| ink(pixels, color, y * self.width + x, 24);
                }
            }
            for (0..g.h) |row| {
                for (0..g.w) |col| {
                    const alpha = coverage[g.offset + row * g.w + col];
                    if (alpha > 0) {
                        const index = (g.y + row) * self.width + g.x + col;
                        ink(pixels, color, index, alpha);
                        if (g.bold) ink(pixels, color, index + 1, alpha);
                    }
                }
            }
            if (g.underline_end > g.underline_start) {
                for (baseline + 5..baseline + 7) |y| {
                    for (g.underline_start..g.underline_end) |x| ink(pixels, color, y * self.width + x, 255);
                }
            }
        }
    }
};

fn ink(pixels: []u8, color: [3]u8, idx: usize, alpha: u8) void {
    const p = pixels[idx * 4 ..][0..4];
    p.* = .{ color[0], color[1], color[2], @max(p[3], alpha) };
}

pub const Workspace = struct {
    rgba: [width_max * height_max * 4]u8,
    compressed: [width_max * height_max * 4 + 8192]u8,
    compressor: std.compress.zlib.Compressor(std.io.FixedBufferStream([]u8).Writer),

    fn compress(self: *Workspace, pixels: []const u8) ![]const u8 {
        var output = std.io.fixedBufferStream(&self.compressed);
        const writer = output.writer();
        // Zig 0.14's zlib initializer returns the whole deflater by value.
        // Initialize its state in place to avoid large copies in debug builds.
        self.compressor = .{
            .wrt = writer,
            .level = @TypeOf(self.compressor.level).get(.fast),
            .block_writer = undefined,
        };
        self.compressor.block_writer = @TypeOf(self.compressor.block_writer).init(writer);
        try writer.writeAll("\x78\x9c"); // zlib header for the default 32 KiB window
        var input = std.io.fixedBufferStream(pixels);
        try self.compressor.compress(input.reader());
        try self.compressor.finish();
        return output.getWritten();
    }
};

pub fn display(storage: *?*Workspace, text: []const u8, level: usize, indent: usize, style: *term.Style, out: anytype) !bool {
    assert(level >= 1 and level <= 3);
    if (level == 3) assert(std.mem.startsWith(u8, text, term.h3_prefix));
    var layout: Layout = .{};
    if (!layout.measure(text)) return false;
    const rows: usize = if (level == 1) 3 else 2;
    const canvas_height: usize = if (level == 3) height_max else height;
    const columns: usize = @max(1, @as(usize, @intFromFloat(@round(
        @as(f32, @floatFromInt(layout.width * rows)) / (@as(f32, @floatFromInt(canvas_height)) * style.cell_aspect),
    ))));
    const count = layout.width * canvas_height;
    if (rows > style.rows or columns + indent > style.columns or count > style.pixels_left) return false;
    if (storage.* == null) storage.* = std.heap.page_allocator.create(Workspace) catch return false;
    const workspace = storage.*.?;
    style.pixels_left -= @intCast(count);
    const pixels = workspace.rgba[0 .. count * 4];
    const start = if (level == 3) h3_above * layout.width * 4 else 0;
    const end = start + height * layout.width * 4;
    @memset(pixels[0..start], 0);
    layout.paint(pixels[start..end], level);
    @memset(pixels[end..], 0);
    var data = try workspace.compress(pixels);
    // Reserve all rows before placement so a title at the bottom can scroll into view.
    for (1..rows) |_| try out.writeAll("\x1bD");
    try out.print("\x1b[{d}A", .{rows - 1});
    try out.print("\x1b_Ga=T,t=d,f=32,o=z,q=2,C=1,s={d},v={d},c={d},r={d},", .{
        layout.width, canvas_height, columns, rows,
    });
    while (data.len > 0) {
        const n = @min(data.len, 3072);
        var encoded: [4096]u8 = undefined;
        try out.writeAll(if (n == data.len) "m=0;" else "m=1;");
        try out.writeAll(std.base64.standard.Encoder.encode(&encoded, data[0..n]));
        try out.writeAll("\x1b\\");
        data = data[n..];
        if (data.len > 0) try out.writeAll("\x1b_G");
    }
    for (1..rows) |_| try out.writeAll("\r\n");
    return true;
}
