const std = @import("std");
const epoch = std.time.epoch;

pub const system = @embedFile("system_prompt");
pub const compact = @embedFile("compact_prompt");

/// Build the full system prompt: immutable base + date + mutable memory context.
pub fn buildSystemPrompt(allocator: std.mem.Allocator, memory_context: []const u8) ![]const u8 {
    const date = todayStr();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // 1. Immutable base
    try buf.appendSlice(allocator, system);

    // 2. Date context
    try buf.appendSlice(allocator, "\n\nToday is ");
    try buf.appendSlice(allocator, &date);
    try buf.appendSlice(allocator, ".");

    // 3. Mutable memory context
    if (memory_context.len > 0) {
        try buf.appendSlice(allocator, "\n\n");
        try buf.appendSlice(allocator, memory_context);
    }

    return buf.toOwnedSlice(allocator);
}

fn todayStr() [10]u8 {
    const es = epoch.EpochSeconds{ .secs = @intCast(std.time.timestamp()) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();

    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{:0>4}-{:0>2}-{:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1,
    }) catch unreachable;
    return buf;
}

// ─── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "buildSystemPrompt contains base prompt" {
    const result = try buildSystemPrompt(testing.allocator, "");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "personal assistant") != null);
}

test "buildSystemPrompt includes date" {
    const result = try buildSystemPrompt(testing.allocator, "");
    defer testing.allocator.free(result);

    // Should contain "Today is YYYY-MM-DD."
    try testing.expect(std.mem.indexOf(u8, result, "Today is 20") != null);
    // Verify the date pattern ends with a period
    const pos = std.mem.indexOf(u8, result, "Today is ").?;
    try testing.expect(result[pos + "Today is ".len + 10] == '.');
}

test "buildSystemPrompt appends memory context" {
    const result = try buildSystemPrompt(testing.allocator, "## Identity\nI am test bot");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "I am test bot") != null);
    // Memory context comes after the date
    const date_pos = std.mem.indexOf(u8, result, "Today is ").?;
    const ctx_pos = std.mem.indexOf(u8, result, "I am test bot").?;
    try testing.expect(ctx_pos > date_pos);
}

test "buildSystemPrompt empty context omits trailing section" {
    const result = try buildSystemPrompt(testing.allocator, "");
    defer testing.allocator.free(result);

    // Should end with the date period, no trailing double-newline
    try testing.expect(result[result.len - 1] == '.');
}

test "system prompt does not hardcode identity" {
    try testing.expect(std.mem.indexOf(u8, system, "You are cld") == null);
    try testing.expect(std.mem.indexOf(u8, system, "personal assistant") != null);
}
