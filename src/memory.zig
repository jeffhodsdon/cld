const std = @import("std");

const Memory = @This();

allocator: std.mem.Allocator,
root_path: []const u8,
long_term: ?[]const u8,

pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Memory {
    // Try to load long-term memory
    const lt = readFileAlloc(allocator, root_path, "long-term.md") catch null;

    return .{
        .allocator = allocator,
        .root_path = root_path,
        .long_term = lt,
    };
}

pub fn deinit(self: *Memory) void {
    if (self.long_term) |lt| {
        self.allocator.free(lt);
    }
}

/// Build context string for provider prompt injection
pub fn getContext(self: *Memory) ![]const u8 {
    var buf = std.ArrayList(u8).init(self.allocator);
    errdefer buf.deinit();

    if (self.long_term) |lt| {
        try buf.appendSlice("## Long-term Memory\n");
        try buf.appendSlice(lt);
        try buf.appendSlice("\n");
    }

    // TODO: load recent tiny.md files and append
    // TODO: on-demand full.md expansion

    return buf.toOwnedSlice();
}

/// Append a line to today's full log
pub fn appendToday(self: *Memory, content: []const u8) !void {
    _ = self;
    _ = content;
    // TODO: write to {root_path}/YYYY-MM-DD.full.md
}

fn readFileAlloc(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 1024);
}
