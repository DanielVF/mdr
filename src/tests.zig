const std = @import("std");
const md = @import("markdown.zig");

fn expectRender(input: []const u8, expected: []const u8) !void {
    var source = std.io.fixedBufferStream(input);
    var output: [1024]u8 = undefined;
    var dest = std.io.fixedBufferStream(&output);
    var line: u32 = 0;
    try md.render(source.reader(), dest.writer(), &line);
    try std.testing.expectEqualStrings(expected, dest.getWritten());
}

test "blocks and simple inline spans" {
    try expectRender("# Hello\r\n\n- **one** and _two_\n2. three\n> `*four*`", "Hello\n\n• one and two\n2. three\n│ *four*");
    try expectRender("[read](file:///etc/passwd) ![alt](https://example.org/i) ![](a)", "read alt ");
    try expectRender("<img src='x'>\n+ missing **closer", "<img src='x'>\n• missing **closer");
    try expectRender("", "");
}

test "fences are literal until closed by the same or longer fence" {
    try expectRender("~~~zig\n\t**hello**\n~~~~\n*done*\n", "    **hello**\ndone\n");
    try expectRender("````\n# x\n```", "# x\n```");
}

test "unsafe bytes fail before any part of their line is written" {
    for ([_][]const u8{ "\xff", "\x00", "\x1b", "\r", "\x7f", "\u{009b}", "\u{202e}", "\u{2069}" }) |bad| {
        var buf: [32]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buf, "```\nok\nbad{s}", .{bad});
        var source = std.io.fixedBufferStream(bytes);
        var output: [32]u8 = undefined;
        var dest = std.io.fixedBufferStream(&output);
        var line: u32 = 0;
        const err = if (bad[0] == 0xff) error.Encoding else error.Control;
        try std.testing.expectError(err, md.render(source.reader(), dest.writer(), &line));
        try std.testing.expectEqualStrings("ok\n", dest.getWritten());
        try std.testing.expectEqual(3, line);
    }
}

fn discard(bytes: []const u8) !void {
    var input = std.io.fixedBufferStream(bytes);
    var line: u32 = 0;
    try md.render(input.reader(), std.io.null_writer, &line);
}

test "line and document limits include their upper bound" {
    const bytes = try std.testing.allocator.alloc(u8, md.document_max + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, '[');
    try discard(bytes[0..md.line_max]);
    try std.testing.expectError(error.LineLimit, discard(bytes[0 .. md.line_max + 1]));
    var i: usize = md.line_max - 1;
    while (i < bytes.len) : (i += md.line_max) bytes[i] = '\n';
    try discard(bytes[0..md.document_max]);
    try std.testing.expectError(error.DocumentLimit, discard(bytes));
}

test "UTF-8 sequence across a read boundary" {
    var bytes = [_]u8{'a'} ** 8194;
    @memcpy(bytes[8191..], "猫");
    var source = std.io.fixedBufferStream(&bytes);
    var out: [bytes.len]u8 = undefined;
    var dest = std.io.fixedBufferStream(&out);
    var line: u32 = 0;
    try md.render(source.reader(), dest.writer(), &line);
    try std.testing.expectEqualSlices(u8, &bytes, dest.getWritten());
}

test "ordinary prose and identifiers retain literal punctuation" {
    try expectRender("2 * 3 * 4 and snake_case_name", "2 * 3 * 4 and snake_case_name");
}

test "terminal headings and scoped link underlines" {
    var source = std.io.fixedBufferStream("# A [link](hidden)\n## 猫\n![alt](x) and [here](y)");
    var bytes: [256]u8 = undefined;
    var dest = std.io.fixedBufferStream(&bytes);
    var line: u32 = 0;
    try md.renderStyled(source.reader(), dest.writer(), &line, .{
        .colors = true,
        .graphics = true,
        .pixels_left = 1,
    });
    try std.testing.expectEqualStrings("\x1b[38;5;167mA \x1b[4mlink\x1b[24m\x1b[39m\n" ++
        "\x1b[38;5;167m猫\x1b[39m\nalt and \x1b[4mhere\x1b[24m", dest.getWritten());
}

test "graphics use the embedded face and stay within the viewport" {
    var bytes: [32768]u8 = undefined;
    var dest = std.io.fixedBufferStream(&bytes);
    var line: u32 = 0;
    var input = std.io.fixedBufferStream("# Lusitana\n## Étude\n### Étude\n# 猫");
    try md.renderStyled(input.reader(), dest.writer(), &line, .{ .colors = true, .graphics = true });
    const stream = dest.getWritten();
    try std.testing.expectEqual(3, std.mem.count(u8, stream, "\x1b_Ga=T"));
    try std.testing.expect(std.mem.indexOf(u8, stream, ",r=3,") != null);
    try std.testing.expectEqual(2, std.mem.count(u8, stream, ",r=2,"));
    try std.testing.expectEqual(1, std.mem.count(u8, stream, ",v=106,"));
    try std.testing.expect(std.mem.endsWith(u8, stream, "\x1b[38;5;167m猫\x1b[39m"));
    dest.reset();
    input.reset();
    try md.renderStyled(input.reader(), dest.writer(), &line, .{ .colors = true, .graphics = true, .columns = 1 });
    try std.testing.expect(std.mem.indexOf(u8, dest.getWritten(), "\x1b_G") == null);
    try std.testing.expect(std.mem.indexOf(u8, dest.getWritten(), "\x1b[38;5;241m### \x1b[38;5;166mÉtude") != null);
}

test "unsafe title is rejected before emitting terminal commands" {
    var input = std.io.fixedBufferStream("# [safe](\x1b)");
    var bytes: [128]u8 = undefined;
    var dest = std.io.fixedBufferStream(&bytes);
    var line: u32 = 0;
    try std.testing.expectError(error.Control, md.renderStyled(input.reader(), dest.writer(), &line, .{
        .colors = true,
        .graphics = true,
    }));
    try std.testing.expectEqual(0, dest.pos);
}

test "code runs and table lookahead preserve ordinary text" {
    try expectRender("literal | pipe\nA | B\n--- | :---:\n猫 | ``a`b``", "literal | pipe\nA   │  B \n────┼────\n猫  │ a`b");
    try expectRender("| a | b |\n| ---: | --- |\n| 1 | x\\|y |", "  a │ b  \n────┼────\n  1 │ x|y");
    try expectRender("| not | a table |\n| -- | --- |", "| not | a table |\n| -- | --- |");
    try expectRender("~~~\nA | B\n--- | ---\n~~~\n", "A | B\n--- | ---\n");
    try expectRender("unclosed ``a` and ```no", "unclosed ``a` and ```no");
}

test "terminal styles for strong, code spans and fenced literal code" {
    var input = std.io.fixedBufferStream("**bold** __again__ `` a`b ``\n```zig\n  **x**\n```\nafter");
    var buf: [256]u8 = undefined;
    var dest = std.io.fixedBufferStream(&buf);
    var line: u32 = 0;
    try md.renderStyled(input.reader(), dest.writer(), &line, .{ .colors = true });
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[22m \x1b[1magain\x1b[22m \x1b[3ma`b\x1b[23m\n" ++
        "\x1b[38;5;109m│   **x**\x1b[39m\nafter", dest.getWritten());
}

test "indented code preserves markup and does not interrupt prose" {
    try expectRender("    # code\n\t**literal**\ntext\n    **prose**\n\n    `x`", "# code\n**literal**\ntext\n    prose\n\n`x`");
}

test "heading whitespace, closing hashes, and deeply indented continuations" {
    try expectRender("#\tTitle\t###  \n   ## C#\n## ###\n### Title###", "Title\n   C#\n\nTitle###");
    try expectRender("-\tone\n+\ttwo\n*\tthree", "• one\n• two\n• three");
    try expectRender("paragraph\n    # example\n    - item\n    > quote\n    head | cell\n--- | ---", "paragraph\n    # example\n    - item\n    > quote\n    head | cell\n--- | ---");
}

test "block openers take precedence over both table headers and rows" {
    const table = "A | B\n--- | ---\n";
    const rendered = "A   │ B  \n────┼────\n";
    const Case = struct { source: []const u8, expected: []const u8 };
    inline for ([_]Case{
        .{ .source = "# Heading | subtitle", .expected = "Heading | subtitle" },
        .{ .source = "-\titem | more", .expected = "• item | more" },
        .{ .source = "  > quote | more", .expected = "  │ quote | more" },
        .{ .source = "1. item | more", .expected = "1. item | more" },
    }) |case| {
        try expectRender(table ++ case.source, rendered ++ case.expected);
        try expectRender(case.source ++ "\n--- | ---", case.expected ++ "\n--- | ---");
    }
    try expectRender(table ++ "```lang | info\n# literal | code\n```", rendered ++ "# literal | code\n");
}

test "table padding is capped per cell and dividers span wide columns" {
    const wide = "x" ** 82;
    try expectRender(wide ++ " | end\n---: | ---\n" ++ wide[1..] ++ " | end\nx | end", wide ++ " │ end\n" ++ "─" ** 82 ++ "─┼────\n " ++ wide[1..] ++ " │ end\n" ++ " " ** 80 ++ "x │ end");
}

test "table widths follow displayed emoji across inline boundaries" {
    try expectRender("abc | end\n--- | ---\n👩‍💻 | end\n[👩🏾](x)‍`💻` | end\n❤️ | end\n♥︎ | end\n1️⃣ | end\na‍b | end", "abc │ end\n────┼────\n👩‍💻  │ end\n👩🏾‍💻  │ end\n❤️  │ end\n♥︎   │ end\n1️⃣  │ end\na‍b  │ end");
}

test "Unicode identifiers preserve underscores beside letters and combining marks" {
    try expectRender("naïve_été_total 猫__語__句 á_β_я", "naïve_été_total 猫__語__句 á_β_я");
    try expectRender("«_été_» and _猫_。", "«été» and 猫。");
}
