const std = @import("std");
const libc = @cImport(@cInclude("stdlib.h"));

const Config = @This();

pub const IMessageConfig = struct {
    allowed_senders: []const []const u8 = &.{},
};

pub const AdaptersConfig = struct {
    imessage: IMessageConfig = .{},
};

pub const TasksConfig = struct {
    compact: ?[]const u8 = null, // cron expression override
};

/// JSON-parseable schema (no runtime-only fields).
const Schema = struct {
    adapters: AdaptersConfig = .{},
    tasks: ?TasksConfig = null,
};

adapters: AdaptersConfig = .{},
tasks: ?TasksConfig = null,

/// Arena backing parsed string slices. Null when using defaults.
arena: ?*std.heap.ArenaAllocator = null,

pub fn load(allocator: std.mem.Allocator) Config {
    const home = std.posix.getenv("HOME") orelse return .{};
    const path = std.fs.path.join(allocator, &.{ home, ".config", "cld", "config.json" }) catch return .{};
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return .{};
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return .{};
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(Schema, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};

    return .{
        .adapters = parsed.value.adapters,
        .tasks = parsed.value.tasks,
        .arena = parsed.arena,
    };
}

pub fn deinit(self: *Config) void {
    if (self.arena) |arena| {
        const allocator = arena.child_allocator;
        arena.deinit();
        allocator.destroy(arena);
        self.arena = null;
    }
}

pub fn isSenderAllowed(self: *const Config, sender: []const u8) bool {
    const allowed = self.adapters.imessage.allowed_senders;
    if (allowed.len == 0) return true;
    for (allowed) |s| {
        if (std.mem.eql(u8, s, sender)) return true;
    }
    return false;
}

fn parseTestConfig(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(Schema) {
    return std.json.parseFromSlice(Schema, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "parse full config" {
    const json =
        \\{
        \\  "adapters": {
        \\    "imessage": {
        \\      "allowed_senders": ["+12125551234", "+14155559876"]
        \\    }
        \\  }
        \\}
    ;
    var parsed = try parseTestConfig(std.testing.allocator, json);
    defer parsed.deinit();
    const cfg = parsed.value;

    try std.testing.expectEqual(2, cfg.adapters.imessage.allowed_senders.len);
    try std.testing.expectEqualStrings("+12125551234", cfg.adapters.imessage.allowed_senders[0]);
    try std.testing.expectEqualStrings("+14155559876", cfg.adapters.imessage.allowed_senders[1]);
}

test "parse empty JSON uses defaults" {
    var parsed = try parseTestConfig(std.testing.allocator, "{}");
    defer parsed.deinit();
    const cfg = parsed.value;

    try std.testing.expectEqual(0, cfg.adapters.imessage.allowed_senders.len);
}

test "parse partial config — adapters only" {
    const json =
        \\{
        \\  "adapters": {
        \\    "imessage": {
        \\      "allowed_senders": ["+10000000000"]
        \\    }
        \\  }
        \\}
    ;
    var parsed = try parseTestConfig(std.testing.allocator, json);
    defer parsed.deinit();
    const cfg = parsed.value;

    try std.testing.expectEqual(1, cfg.adapters.imessage.allowed_senders.len);
}

test "isSenderAllowed with allowlist" {
    var parsed = try parseTestConfig(std.testing.allocator,
        \\{"adapters":{"imessage":{"allowed_senders":["+1111","+2222"]}}}
    );
    defer parsed.deinit();
    const cfg = &parsed.value;

    const config: Config = .{
        .adapters = cfg.adapters,
    };

    try std.testing.expect(config.isSenderAllowed("+1111"));
    try std.testing.expect(config.isSenderAllowed("+2222"));
    try std.testing.expect(!config.isSenderAllowed("+9999"));
}

test "isSenderAllowed empty list allows everyone" {
    const config: Config = .{};

    try std.testing.expect(config.isSenderAllowed("+anything"));
    try std.testing.expect(config.isSenderAllowed(""));
}

test "load missing file returns defaults" {
    // load() reads HOME env; point it at a dir with no config file
    const original_home = std.posix.getenv("HOME");
    _ = libc.setenv("HOME", "/nonexistent", 1);
    defer {
        if (original_home) |h| _ = libc.setenv("HOME", h.ptr, 1);
    }

    var config = Config.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(0, config.adapters.imessage.allowed_senders.len);
    try std.testing.expect(config.arena == null);
}
