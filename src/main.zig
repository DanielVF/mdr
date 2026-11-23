const std = @import("std");
const markdown = @import("markdown.zig");

// A read may block indefinitely on a live pipe. Publish completed terminal
// output first, including any table the renderer has finished.
const StreamingInput = struct {
    file: std.fs.File,
    flush_before_read: ?*std.io.BufferedWriter(4096, std.fs.File.Writer),

    pub fn read(self: StreamingInput, bytes: []u8) !usize {
        if (self.flush_before_read) |output| try output.flush();
        return self.file.read(bytes);
    }
};

pub fn main() u8 {
    var line_number: u32 = 1;
    run(&line_number) catch |err| {
        const reason: []const u8 = switch (err) {
            error.Arguments => "usage: mdr [FILE|-]",
            error.Open => "cannot open input file",
            error.LineLimit => "line exceeds 64 KiB",
            error.DocumentLimit => "document exceeds 8 MiB",
            error.Encoding => "invalid UTF-8",
            error.Control => "disallowed control character",
            else => "I/O failure",
        };
        const stderr = std.io.getStdErr().writer();
        (switch (err) {
            error.Arguments, error.Open => stderr.print("mdr: {s}\n", .{reason}),
            else => stderr.print("mdr: line {d}: {s}\n", .{ line_number, reason }),
        }) catch {};
        return 1;
    };
    return 0;
}

fn run(line_number: *u32) !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next();
    if (args.next() != null) return error.Arguments;
    var input = std.io.getStdIn();
    const from_file = if (path) |p| !std.mem.eql(u8, p, "-") else false;
    if (from_file) input = std.fs.cwd().openFile(path.?, .{}) catch return error.Open;
    defer if (from_file) input.close();
    const stdout = std.io.getStdOut();
    var output = std.io.bufferedWriter(stdout.writer());
    const stream: StreamingInput = .{ .file = input, .flush_before_read = if (stdout.isTty()) &output else null };
    markdown.renderStyled(stream, output.writer(), line_number, @import("terminal.zig").Style.detect()) catch |err| {
        switch (err) {
            error.Encoding, error.Control, error.DocumentLimit, error.LineLimit => try output.flush(),
            else => {},
        }
        return err;
    };
    try output.flush();
}
