const std = @import("std");

const Cmd = @This();

arena: std.heap.ArenaAllocator,
argv: std.ArrayListUnmanaged([]const u8),
env_removals: std.ArrayListUnmanaged([]const u8),
env_overrides: std.ArrayListUnmanaged(Override),
cwd: ?[]const u8,

const Override = struct {
    key: []const u8,
    value: []const u8,
};

pub fn init(allocator: std.mem.Allocator, exe: []const u8) Cmd {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const aa = arena.allocator();
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(aa, aa.dupe(u8, exe) catch @panic("OOM")) catch @panic("OOM");

    return .{
        .arena = arena,
        .argv = argv,
        .env_removals = .empty,
        .env_overrides = .empty,
        .cwd = null,
    };
}

pub fn deinit(self: *Cmd) void {
    self.arena.deinit();
}

pub fn arg(self: *Cmd, value: []const u8) !void {
    const aa = self.arena.allocator();
    const duped = try aa.dupe(u8, value);
    try self.argv.append(aa, duped);
}

pub fn option(self: *Cmd, flag: []const u8, value: []const u8) !void {
    try self.arg(flag);
    try self.arg(value);
}

pub fn envRemove(self: *Cmd, key: []const u8) !void {
    const aa = self.arena.allocator();
    const duped = try aa.dupe(u8, key);
    try self.env_removals.append(aa, duped);
}

pub fn envSet(self: *Cmd, key: []const u8, value: []const u8) !void {
    const aa = self.arena.allocator();
    try self.env_overrides.append(aa, .{
        .key = try aa.dupe(u8, key),
        .value = try aa.dupe(u8, value),
    });
}

/// Build a modified EnvMap. Returns null if no env changes were requested.
/// Caller owns the returned EnvMap and must call deinit() on it.
pub fn buildEnvMap(self: *Cmd, allocator: std.mem.Allocator) !?std.process.EnvMap {
    if (self.env_removals.items.len == 0 and self.env_overrides.items.len == 0) {
        return null;
    }

    var env = try std.process.getEnvMap(allocator);

    for (self.env_removals.items) |key| {
        env.remove(key);
    }

    for (self.env_overrides.items) |ov| {
        try env.put(ov.key, ov.value);
    }

    return env;
}

// --- Tests ---

const testing = std.testing;

test "init sets exe as argv[0]" {
    var cmd = Cmd.init(testing.allocator, "echo");
    defer cmd.deinit();

    try testing.expectEqual(@as(usize, 1), cmd.argv.items.len);
    try testing.expectEqualStrings("echo", cmd.argv.items[0]);
}

test "arg appends to argv" {
    var cmd = Cmd.init(testing.allocator, "echo");
    defer cmd.deinit();

    try cmd.arg("hello");
    try cmd.arg("world");

    try testing.expectEqual(@as(usize, 3), cmd.argv.items.len);
    try testing.expectEqualStrings("echo", cmd.argv.items[0]);
    try testing.expectEqualStrings("hello", cmd.argv.items[1]);
    try testing.expectEqualStrings("world", cmd.argv.items[2]);
}

test "option appends flag and value" {
    var cmd = Cmd.init(testing.allocator, "curl");
    defer cmd.deinit();

    try cmd.option("-H", "Content-Type: application/json");

    try testing.expectEqual(@as(usize, 3), cmd.argv.items.len);
    try testing.expectEqualStrings("-H", cmd.argv.items[1]);
    try testing.expectEqualStrings("Content-Type: application/json", cmd.argv.items[2]);
}

test "envRemove tracks removal" {
    var cmd = Cmd.init(testing.allocator, "env");
    defer cmd.deinit();

    try cmd.envRemove("HOME");
    try cmd.envRemove("PATH");

    try testing.expectEqual(@as(usize, 2), cmd.env_removals.items.len);
    try testing.expectEqualStrings("HOME", cmd.env_removals.items[0]);
    try testing.expectEqualStrings("PATH", cmd.env_removals.items[1]);
}

test "envSet tracks override" {
    var cmd = Cmd.init(testing.allocator, "env");
    defer cmd.deinit();

    try cmd.envSet("FOO", "bar");

    try testing.expectEqual(@as(usize, 1), cmd.env_overrides.items.len);
    try testing.expectEqualStrings("FOO", cmd.env_overrides.items[0].key);
    try testing.expectEqualStrings("bar", cmd.env_overrides.items[0].value);
}

test "buildEnvMap returns null when no changes" {
    var cmd = Cmd.init(testing.allocator, "echo");
    defer cmd.deinit();

    const result = try cmd.buildEnvMap(testing.allocator);
    try testing.expect(result == null);
}

test "buildEnvMap applies removals and overrides" {
    var cmd = Cmd.init(testing.allocator, "env");
    defer cmd.deinit();

    try cmd.envSet("TEST_CLD_KEY", "test_value");
    try cmd.envRemove("TEST_CLD_NONEXISTENT");

    var env = (try cmd.buildEnvMap(testing.allocator)).?;
    defer env.deinit();

    try testing.expectEqualStrings("test_value", env.get("TEST_CLD_KEY").?);
    try testing.expect(env.get("TEST_CLD_NONEXISTENT") == null);
}
