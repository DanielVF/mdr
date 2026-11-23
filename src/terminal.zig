const std = @import("std");
const builtin = @import("builtin");

pub const bold = "\x1b[1m";
pub const bold_end = "\x1b[22m";
pub const InlineStyle = enum {
    plain,
    neutral,
    dark,
    light,

    pub fn code(self: InlineStyle) []const u8 {
        return switch (self) {
            .plain => "",
            .neutral => "\x1b[3m",
            .dark => "\x1b[48;5;235m",
            .light => "\x1b[48;5;254m",
        };
    }

    pub fn codeEnd(self: InlineStyle) []const u8 {
        return switch (self) {
            .plain => "",
            .neutral => "\x1b[23m",
            .dark, .light => "\x1b[49m",
        };
    }

    fn detect() InlineStyle {
        if (builtin.os.tag == .windows) return .neutral;
        const hint = std.posix.getenv("COLORFGBG") orelse return .neutral;
        var fields = std.mem.splitBackwardsScalar(u8, hint, ';');
        const bg = std.fmt.parseInt(u8, fields.first(), 10) catch return .neutral;
        return switch (bg) {
            0, 16, 232...238 => .dark,
            7, 15, 231, 250...255 => .light,
            else => .neutral,
        };
    }
};
pub const block = "\x1b[38;5;109m";
pub const h3_prefix = "### ";
pub const h3_gray = "\x1b[38;5;241m";
pub const orange_red = "\x1b[38;5;166m";
pub const red = "\x1b[38;5;167m";
pub const underline = "\x1b[4m";
pub const underline_end = "\x1b[24m";
pub const foreground_end = "\x1b[39m";

pub const Style = struct {
    colors: bool = false,
    inline_style: InlineStyle = .neutral,

    graphics: bool = false,
    columns: u32 = 80,
    rows: u32 = 24,
    // Pixel width / height of one terminal cell.
    cell_aspect: f32 = 0.5,
    pixels_left: u32 = 16 * 1024 * 1024,

    pub fn inlineStyle(self: Style) InlineStyle {
        return if (self.colors) self.inline_style else .plain;
    }

    pub fn detect() Style {
        const file = std.io.getStdOut();
        if (!file.isTty()) return .{};
        var result: Style = .{ .colors = true, .inline_style = InlineStyle.detect(), .graphics = true };
        if (builtin.os.tag == .linux) {
            var size = std.mem.zeroes(std.posix.winsize);
            const err = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
            if (std.posix.errno(err) == .SUCCESS and size.col > 0) {
                result.columns = size.col;
                if (size.row > 0) result.rows = size.row;
                if (size.row > 0 and size.xpixel > 0 and size.ypixel > 0) {
                    const ratio = @as(f32, @floatFromInt(@as(u32, size.xpixel) * size.row)) /
                        @as(f32, @floatFromInt(@as(u32, size.ypixel) * size.col));
                    result.cell_aspect = std.math.clamp(ratio, 0.2, 1.5);
                }
            }
        }
        return result;
    }
};
