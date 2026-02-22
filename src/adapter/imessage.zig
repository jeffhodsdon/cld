const std = @import("std");
const root = @import("adapter");
const Adapter = root.Adapter;
const msg = @import("message");
const InboundMessage = msg.InboundMessage;
const OutboundMessage = msg.OutboundMessage;
const SendError = msg.SendError;
const Cmd = @import("Cmd");
const ProcessPool = @import("ProcessPool");

const IMessage = @This();

allocator: std.mem.Allocator,
pool: *ProcessPool,
watch_id: ?ProcessPool.Id,
parse_arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, pool: *ProcessPool) !IMessage {
    // Spawn: imsg watch --json
    var cmd = Cmd.init(allocator, "imsg");
    defer cmd.deinit();
    try cmd.arg("watch");
    try cmd.arg("--json");

    const watch_id = try pool.spawn(&cmd, .{ .stderr = .pipe });

    return .{
        .allocator = allocator,
        .pool = pool,
        .watch_id = watch_id,
        .parse_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *IMessage) void {
    self.parse_arena.deinit();
    if (self.watch_id) |wid| {
        self.pool.kill(wid);
        self.pool.remove(wid);
        self.watch_id = null;
    }
}

pub fn adapter(self: *IMessage) Adapter {
    return .{
        .ptr = @ptrCast(self),
        .vtable = &.{
            .poll = &pollFn,
            .send = &sendFn,
            .deinit = &deinitFn,
        },
    };
}

fn pollFn(ptr: *anyopaque) ?InboundMessage {
    const self: *IMessage = @ptrCast(@alignCast(ptr));
    const wid = self.watch_id orelse return null;
    const proc = self.pool.get(wid) orelse return null;

    const lines = proc.drainStdout() catch return null;
    if (lines.len == 0) return null;

    // Reset arena each poll cycle
    _ = self.parse_arena.reset(.retain_capacity);

    // Process lines newest-first, return first valid message
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (parseJsonMessage(self.parse_arena.allocator(), lines[i])) |message| {
            return message;
        }
    }
    return null;
}

fn sendFn(ptr: *anyopaque, message: OutboundMessage) SendError!void {
    const self: *IMessage = @ptrCast(@alignCast(ptr));

    // Strip "imessage:" prefix from channel_id to get the recipient
    const recipient = if (std.mem.startsWith(u8, message.channel_id, "imessage:"))
        message.channel_id["imessage:".len..]
    else
        message.channel_id;

    var cmd = Cmd.init(self.allocator, "imsg");
    defer cmd.deinit();
    cmd.arg("send") catch return SendError.AdapterFailed;
    cmd.option("--to", recipient) catch return SendError.AdapterFailed;
    cmd.option("--text", message.text) catch return SendError.AdapterFailed;

    var result = ProcessPool.exec(self.allocator, &cmd) catch return SendError.AdapterFailed;
    defer result.deinit();

    if (result.exit_code != 0) {
        if (result.stdout.len > 0) std.log.err("imsg send stdout: {s}", .{result.stdout});
        if (result.stderr.len > 0) std.log.err("imsg send stderr: {s}", .{result.stderr});
        std.log.err("imsg send exited with code {d}", .{result.exit_code});
        return SendError.AdapterFailed;
    }
}

fn deinitFn(ptr: *anyopaque) void {
    const self: *IMessage = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn parseJsonMessage(allocator: std.mem.Allocator, line: []const u8) ?InboundMessage {
    const parsed = std.json.parseFromSlice(struct {
        guid: []const u8,
        sender: []const u8,
        text: ?[]const u8 = null,
        created_at: []const u8,
        is_from_me: bool,
        is_reaction: bool = false,
        reply_to_guid: ?[]const u8 = null,
    }, allocator, line, .{ .ignore_unknown_fields = true }) catch return null;

    const v = parsed.value;

    // Skip self-sent messages and reactions
    if (v.is_from_me) return null;
    if (v.is_reaction) return null;

    const timestamp = parseIso8601(v.created_at) orelse return null;
    const channel_id = std.fmt.allocPrint(allocator, "imessage:{s}", .{v.sender}) catch return null;

    return .{
        .id = v.guid,
        .channel_id = channel_id,
        .sender = v.sender,
        .text = v.text orelse "",
        .timestamp = timestamp,
        .reply_to = v.reply_to_guid,
    };
}

/// Parse ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SS) to epoch seconds.
/// Ignores fractional seconds, assumes UTC.
fn parseIso8601(s: []const u8) ?i64 {
    // Minimum: "YYYY-MM-DDTHH:MM:SS" = 19 chars
    if (s.len < 19) return null;

    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u16, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u16, s[8..10], 10) catch return null;
    if (s[10] != 'T') return null;
    const hour = std.fmt.parseInt(u16, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const minute = std.fmt.parseInt(u16, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const second = std.fmt.parseInt(u16, s[17..19], 10) catch return null;

    // Compute days from epoch (1970-01-01) to the given date
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (std.time.epoch.isLeapYear(y)) @as(i64, 366) else 364 + 1;
    }

    // Days for completed months in the target year
    const month_days = [_]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u16 = 1;
    while (m < month) : (m += 1) {
        days += month_days[m - 1];
        if (m == 2 and std.time.epoch.isLeapYear(year)) days += 1;
    }

    days += day - 1; // day is 1-based

    return days * std.time.epoch.secs_per_day +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);
}

// ─── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const valid_json =
    \\{"id":2329,"chat_id":1,"guid":"E37CE941-ABCD-1234-5678-9ABCDEF01234","sender":"+17034055338","text":"hello world","created_at":"2026-02-06T23:16:42.284Z","is_from_me":false,"is_reaction":false,"reply_to_guid":null,"destination_caller_id":null,"attachments":[],"reactions":[]}
;

fn testAllocator() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "parse valid message" {
    var arena = testAllocator();
    defer arena.deinit();
    const m = parseJsonMessage(arena.allocator(), valid_json) orelse
        return error.ExpectedMessage;

    try testing.expectEqualStrings("E37CE941-ABCD-1234-5678-9ABCDEF01234", m.id);
    try testing.expectEqualStrings("+17034055338", m.sender);
    try testing.expectEqualStrings("hello world", m.text);
    try testing.expect(m.reply_to == null);
}

test "parse sets channel_id prefix" {
    var arena = testAllocator();
    defer arena.deinit();
    const m = parseJsonMessage(arena.allocator(), valid_json) orelse
        return error.ExpectedMessage;

    try testing.expectEqualStrings("imessage:+17034055338", m.channel_id);
}

test "parse skips is_from_me" {
    var arena = testAllocator();
    defer arena.deinit();
    const json =
        \\{"id":1,"chat_id":1,"guid":"G1","sender":"+1","text":"hi","created_at":"2026-02-06T23:16:42Z","is_from_me":true,"is_reaction":false}
    ;
    try testing.expect(parseJsonMessage(arena.allocator(), json) == null);
}

test "parse skips reactions" {
    var arena = testAllocator();
    defer arena.deinit();
    const json =
        \\{"id":1,"chat_id":1,"guid":"G1","sender":"+1","text":"Loved \"hi\"","created_at":"2026-02-06T23:16:42Z","is_from_me":false,"is_reaction":true}
    ;
    try testing.expect(parseJsonMessage(arena.allocator(), json) == null);
}

test "parse handles null text" {
    var arena = testAllocator();
    defer arena.deinit();
    const json =
        \\{"id":1,"chat_id":1,"guid":"G2","sender":"+1","text":null,"created_at":"2026-02-06T23:16:42Z","is_from_me":false,"is_reaction":false}
    ;
    const m = parseJsonMessage(arena.allocator(), json) orelse
        return error.ExpectedMessage;

    try testing.expectEqualStrings("", m.text);
}

test "parse rejects malformed JSON" {
    var arena = testAllocator();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parseJsonMessage(a, "not json") == null);
    try testing.expect(parseJsonMessage(a, "") == null);
    try testing.expect(parseJsonMessage(a, "{}") == null);
}

test "parse ISO 8601 timestamp" {
    var arena = testAllocator();
    defer arena.deinit();
    const m = parseJsonMessage(arena.allocator(), valid_json) orelse
        return error.ExpectedMessage;

    try testing.expect(m.timestamp > 1767225600); // > 2026-01-01
    try testing.expect(m.timestamp < 1798761600); // < 2027-01-01

    const expected = parseIso8601("2026-02-06T23:16:42.284Z") orelse return error.ParseFailed;
    try testing.expectEqual(expected, m.timestamp);
}

test "parseIso8601 known value" {
    // 1970-01-01T00:00:00Z = epoch 0
    try testing.expectEqual(@as(i64, 0), parseIso8601("1970-01-01T00:00:00Z").?);

    // 2000-01-01T00:00:00Z = 946684800
    try testing.expectEqual(@as(i64, 946684800), parseIso8601("2000-01-01T00:00:00Z").?);

    // Too short
    try testing.expect(parseIso8601("2026-02-06") == null);
}

test "parse reply_to_guid" {
    var arena = testAllocator();
    defer arena.deinit();
    const json =
        \\{"id":1,"chat_id":1,"guid":"G3","sender":"+1","text":"reply","created_at":"2026-02-06T23:16:42Z","is_from_me":false,"is_reaction":false,"reply_to_guid":"ORIGINAL-GUID"}
    ;
    const m = parseJsonMessage(arena.allocator(), json) orelse
        return error.ExpectedMessage;

    try testing.expectEqualStrings("ORIGINAL-GUID", m.reply_to.?);
}
