const std = @import("std");
const epoch = std.time.epoch;

const Memory = @This();

allocator: std.mem.Allocator,
root_path: []const u8,
identity: ?[]const u8,
soul: ?[]const u8,
user_profile: ?[]const u8,
tools: ?[]const u8,
agents: ?[]const u8,
long_term: ?[]const u8,
tinys: std.StringHashMap([]const u8),

pub fn init(allocator: std.mem.Allocator, root_path: []const u8) Memory {
    var self: Memory = .{
        .allocator = allocator,
        .root_path = root_path,
        .identity = readFileAlloc(allocator, root_path, "IDENTITY.md") catch null,
        .soul = readFileAlloc(allocator, root_path, "SOUL.md") catch null,
        .user_profile = readFileAlloc(allocator, root_path, "USER.md") catch null,
        .tools = readFileAlloc(allocator, root_path, "TOOLS.md") catch null,
        .agents = readFileAlloc(allocator, root_path, "AGENTS.md") catch null,
        .long_term = readFileAlloc(allocator, root_path, "MEMORY.md") catch null,
        .tinys = std.StringHashMap([]const u8).init(allocator),
    };

    self.loadRecentTinys(7) catch {};

    return self;
}

pub fn deinit(self: *Memory) void {
    if (self.identity) |v| self.allocator.free(v);
    if (self.soul) |v| self.allocator.free(v);
    if (self.user_profile) |v| self.allocator.free(v);
    if (self.tools) |v| self.allocator.free(v);
    if (self.agents) |v| self.allocator.free(v);
    if (self.long_term) |v| self.allocator.free(v);

    var it = self.tinys.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.tinys.deinit();
}

/// Build context string for provider prompt injection.
/// Concatenates identity files + long-term memory + sorted daily summaries.
pub fn getContext(self: *Memory) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(self.allocator);

    const sections = [_]struct { header: []const u8, content: ?[]const u8 }{
        .{ .header = "## Identity\n", .content = self.identity },
        .{ .header = "## Soul\n", .content = self.soul },
        .{ .header = "## User Profile\n", .content = self.user_profile },
        .{ .header = "## Tools\n", .content = self.tools },
        .{ .header = "## Agents\n", .content = self.agents },
        .{ .header = "## Long-term Memory\n", .content = self.long_term },
    };

    for (sections) |s| {
        if (s.content) |content| {
            try buf.appendSlice(self.allocator, s.header);
            try buf.appendSlice(self.allocator, content);
            try buf.appendSlice(self.allocator, "\n\n");
        }
    }

    // Collect and sort tiny keys for deterministic ordering
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(self.allocator);

    var kit = self.tinys.keyIterator();
    while (kit.next()) |key| {
        try keys.append(self.allocator, key.*);
    }

    // Insertion sort — at most 7 items
    var i: usize = 1;
    while (i < keys.items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, keys.items[j - 1], keys.items[j]) == .gt) {
            const tmp = keys.items[j];
            keys.items[j] = keys.items[j - 1];
            keys.items[j - 1] = tmp;
            j -= 1;
        }
    }

    for (keys.items) |key| {
        const content = self.tinys.get(key).?;
        try buf.appendSlice(self.allocator, "## ");
        try buf.appendSlice(self.allocator, key);
        try buf.appendSlice(self.allocator, " Summary\n");
        try buf.appendSlice(self.allocator, content);
        try buf.appendSlice(self.allocator, "\n\n");
    }

    return buf.toOwnedSlice(self.allocator);
}

/// Append a line to today's full log file.
pub fn appendToday(self: *Memory, content: []const u8) !void {
    const date = todayStr();
    const filename = try std.fmt.allocPrint(self.allocator, "{s}.full.md", .{&date});
    defer self.allocator.free(filename);

    const path = try std.fs.path.join(self.allocator, &.{ self.root_path, filename });
    defer self.allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();

    const end = try file.getEndPos();
    try file.seekTo(end);
    try file.writeAll(content);
    try file.writeAll("\n");
}

/// Convenience: format and append a timestamped log entry.
pub fn logMessage(self: *Memory, direction: []const u8, id: []const u8, text: []const u8) void {
    const entry = std.fmt.allocPrint(self.allocator, "{s} [{s}] {s}", .{ direction, id, text }) catch return;
    defer self.allocator.free(entry);
    self.appendToday(entry) catch {};
}

/// Format current date as YYYY-MM-DD.
pub fn todayStr() [10]u8 {
    return epochToDateStr(@intCast(std.time.timestamp()));
}

fn epochToDateStr(timestamp: u64) [10]u8 {
    const es = epoch.EpochSeconds{ .secs = timestamp };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();

    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{:0>4}-{:0>2}-{:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1,
    }) catch unreachable;
    return buf;
}

/// Parse a claude CLI JSON response line, extracting the result text.
pub fn parseClaudeResult(allocator: std.mem.Allocator, json_line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(struct {
        result: ?[]const u8 = null,
        is_error: bool = false,
    }, allocator, json_line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    if (parsed.value.is_error) return null;
    const result = parsed.value.result orelse return null;
    if (result.len == 0) return null;

    return allocator.dupe(u8, result) catch null;
}

fn loadRecentTinys(self: *Memory, days: u32) !void {
    const now: u64 = @intCast(std.time.timestamp());
    var d: u32 = 0;
    while (d < days) : (d += 1) {
        const ts: u64 = now - @as(u64, d) * 86400;
        const date = epochToDateStr(ts);
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.tiny.md", .{&date});
        defer self.allocator.free(filename);

        if (readFileAlloc(self.allocator, self.root_path, filename)) |content| {
            const key = self.allocator.dupe(u8, &date) catch {
                self.allocator.free(content);
                return error.OutOfMemory;
            };
            self.tinys.put(key, content) catch {
                self.allocator.free(key);
                self.allocator.free(content);
                return error.OutOfMemory;
            };
        } else |_| {}
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 1024);
}

// ─── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "todayStr format validation" {
    const str = todayStr();
    try testing.expect(str.len == 10);
    try testing.expect(str[4] == '-');
    try testing.expect(str[7] == '-');
    // Year should be reasonable
    const year = std.fmt.parseInt(u16, str[0..4], 10) catch return error.BadYear;
    try testing.expect(year >= 2020 and year <= 2100);
}

test "epochToDateStr known date" {
    // Unix epoch = 1970-01-01
    const str = epochToDateStr(0);
    try testing.expectEqualStrings("1970-01-01", &str);
}

test "epochToDateStr known date 2026" {
    // 2026-01-01 00:00:00 UTC = 1767225600
    const str = epochToDateStr(1767225600);
    try testing.expectEqualStrings("2026-01-01", &str);
}

test "getContext with no files returns empty" {
    var mem = Memory.init(testing.allocator, "/nonexistent/path");
    defer mem.deinit();

    const ctx = try mem.getContext();
    defer testing.allocator.free(ctx);

    try testing.expectEqualStrings("", ctx);
}

test "getContext with identity and long-term" {
    const tmp_path = "/tmp/cld-test-ctx";
    std.fs.cwd().deleteTree(tmp_path) catch {};
    try std.fs.cwd().makePath(tmp_path);
    defer {
        std.fs.cwd().deleteTree(tmp_path) catch {};
    }

    try writeTestFile(tmp_path, "IDENTITY.md", "I am cld");
    try writeTestFile(tmp_path, "MEMORY.md", "Remember this");

    var mem = Memory.init(testing.allocator, tmp_path);
    defer mem.deinit();

    const ctx = try mem.getContext();
    defer testing.allocator.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "I am cld") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Remember this") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "## Identity\n") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "## Long-term Memory\n") != null);
}

test "getContext tinys sorted by date" {
    var mem: Memory = .{
        .allocator = testing.allocator,
        .root_path = "/nonexistent",
        .identity = null,
        .soul = null,
        .user_profile = null,
        .tools = null,
        .agents = null,
        .long_term = null,
        .tinys = std.StringHashMap([]const u8).init(testing.allocator),
    };
    defer mem.deinit();

    // Insert in non-sorted order
    try mem.tinys.put(
        try testing.allocator.dupe(u8, "2026-02-21"),
        try testing.allocator.dupe(u8, "day 21"),
    );
    try mem.tinys.put(
        try testing.allocator.dupe(u8, "2026-02-19"),
        try testing.allocator.dupe(u8, "day 19"),
    );
    try mem.tinys.put(
        try testing.allocator.dupe(u8, "2026-02-20"),
        try testing.allocator.dupe(u8, "day 20"),
    );

    const ctx = try mem.getContext();
    defer testing.allocator.free(ctx);

    const pos19 = std.mem.indexOf(u8, ctx, "day 19").?;
    const pos20 = std.mem.indexOf(u8, ctx, "day 20").?;
    const pos21 = std.mem.indexOf(u8, ctx, "day 21").?;
    try testing.expect(pos19 < pos20);
    try testing.expect(pos20 < pos21);
}

test "appendToday creates file and appends content" {
    const tmp_path = "/tmp/cld-test-append";
    std.fs.cwd().deleteTree(tmp_path) catch {};
    try std.fs.cwd().makePath(tmp_path);
    defer {
        std.fs.cwd().deleteTree(tmp_path) catch {};
    }

    var mem = Memory.init(testing.allocator, tmp_path);
    defer mem.deinit();

    try mem.appendToday("hello world");
    try mem.appendToday("second line");

    // Read back
    const date = todayStr();
    const filename = try std.fmt.allocPrint(testing.allocator, "{s}.full.md", .{&date});
    defer testing.allocator.free(filename);

    const content = try readFileAlloc(testing.allocator, tmp_path, filename);
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("hello world\nsecond line\n", content);
}

test "parseClaudeResult valid result" {
    const json =
        \\{"result":"Hello!","is_error":false}
    ;
    const text = parseClaudeResult(testing.allocator, json) orelse
        return error.ExpectedResult;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Hello!", text);
}

test "parseClaudeResult error response" {
    const json =
        \\{"result":"something","is_error":true}
    ;
    try testing.expect(parseClaudeResult(testing.allocator, json) == null);
}

test "parseClaudeResult null result" {
    const json =
        \\{"result":null,"is_error":false}
    ;
    try testing.expect(parseClaudeResult(testing.allocator, json) == null);
}

test "parseClaudeResult empty result" {
    const json =
        \\{"result":"","is_error":false}
    ;
    try testing.expect(parseClaudeResult(testing.allocator, json) == null);
}

test "parseClaudeResult malformed JSON" {
    try testing.expect(parseClaudeResult(testing.allocator, "not json") == null);
    try testing.expect(parseClaudeResult(testing.allocator, "") == null);
    try testing.expect(parseClaudeResult(testing.allocator, "{}") == null);
}

fn writeTestFile(dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    defer testing.allocator.free(path);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}
