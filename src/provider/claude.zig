const std = @import("std");
const root = @import("provider");
const Provider = root.Provider;
const msg = @import("message");
const Request = msg.Request;
const Response = msg.Response;
const Handle = msg.Handle;
const Cmd = @import("Cmd");
const ProcessPool = @import("ProcessPool");
const Uuid = @import("Uuid");

const Claude = @This();

const SessionInfo = struct {
    process_id: ProcessPool.Id,
    session_uuid: []const u8,
    conversation_id: []const u8,
};

allocator: std.mem.Allocator,
pool: *ProcessPool,
sessions: std.AutoHashMap(Handle, SessionInfo),
/// Maps conversation_id → session_uuid for reuse across messages.
conversation_uuids: std.StringHashMap([]const u8),
next_handle: u64,

pub fn init(allocator: std.mem.Allocator, pool: *ProcessPool) Claude {
    return .{
        .allocator = allocator,
        .pool = pool,
        .sessions = std.AutoHashMap(Handle, SessionInfo).init(allocator),
        .conversation_uuids = std.StringHashMap([]const u8).init(allocator),
        .next_handle = 0,
    };
}

pub fn deinit(self: *Claude) void {
    // Kill all active sessions
    var it = self.sessions.valueIterator();
    while (it.next()) |session| {
        self.pool.kill(session.process_id);
        self.pool.remove(session.process_id);
        self.allocator.free(session.conversation_id);
    }
    self.sessions.deinit();

    // Free conversation UUID mappings
    var cit = self.conversation_uuids.iterator();
    while (cit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.conversation_uuids.deinit();
}

pub fn provider(self: *Claude) Provider {
    return .{
        .ptr = @ptrCast(self),
        .vtable = &.{
            .start = &startFn,
            .poll = &pollFn,
            .cancel = &cancelFn,
            .deinit = &deinitFn,
        },
    };
}

/// Check if a given process ID belongs to one of our sessions.
pub fn ownsProcess(self: *Claude, process_id: ProcessPool.Id) bool {
    var it = self.sessions.valueIterator();
    while (it.next()) |session| {
        if (session.process_id == process_id) return true;
    }
    return false;
}

fn buildPrompt(allocator: std.mem.Allocator, messages: []const msg.Message) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (messages) |m| {
        try buf.appendSlice(allocator, m.content);
        try buf.appendSlice(allocator, "\n");
    }
    return buf.toOwnedSlice(allocator);
}

fn buildCmd(allocator: std.mem.Allocator, prompt: []const u8, session_uuid: []const u8, is_resume: bool, system_prompt: []const u8) !Cmd {
    var cmd = Cmd.init(allocator, "claude");
    errdefer cmd.deinit();
    try cmd.arg("-p");
    try cmd.arg(prompt);
    try cmd.option("--output-format", "json");
    if (system_prompt.len > 0) {
        try cmd.option("--system-prompt", system_prompt);
    }
    if (is_resume) {
        try cmd.option("--resume", session_uuid);
    } else {
        try cmd.option("--session-id", session_uuid);
    }
    try cmd.arg("--dangerously-skip-permissions");
    try cmd.envRemove("CLAUDECODE");
    return cmd;
}

fn startFn(ptr: *anyopaque, req: Request) Handle {
    const self: *Claude = @ptrCast(@alignCast(ptr));

    const handle = self.next_handle;
    self.next_handle += 1;

    // Look up existing session UUID for this conversation, or create one.
    const existing = self.conversation_uuids.get(req.conversation_id);
    const is_resume = existing != null;
    const session_uuid = existing orelse blk: {
        const uuid = Uuid.v4();
        const uuid_str = uuid.toStrAlloc(self.allocator) catch return handle;
        const key = self.allocator.dupe(u8, req.conversation_id) catch {
            self.allocator.free(uuid_str);
            return handle;
        };
        self.conversation_uuids.put(key, uuid_str) catch {
            self.allocator.free(uuid_str);
            self.allocator.free(key);
            return handle;
        };
        break :blk uuid_str;
    };

    const prompt = buildPrompt(self.allocator, req.messages) catch return handle;
    defer self.allocator.free(prompt);

    var cmd = buildCmd(self.allocator, prompt, session_uuid, is_resume, req.system_prompt) catch return handle;
    defer cmd.deinit();

    const process_id = self.pool.spawn(&cmd, .{ .stderr = .pipe }) catch return handle;

    const conv_id = self.allocator.dupe(u8, req.conversation_id) catch return handle;

    self.sessions.put(handle, .{
        .process_id = process_id,
        .session_uuid = session_uuid,
        .conversation_id = conv_id,
    }) catch {
        self.pool.kill(process_id);
        self.pool.remove(process_id);
        self.allocator.free(conv_id);
    };

    return handle;
}

fn pollFn(ptr: *anyopaque, handle: Handle) ?Response {
    const self: *Claude = @ptrCast(@alignCast(ptr));

    const session = self.sessions.get(handle) orelse return null;
    const proc = self.pool.get(session.process_id) orelse return null;

    // Check if process has exited
    if (proc.checkExit()) |exit_code| {
        // Log stderr if process failed
        if (exit_code != 0) {
            const stderr = proc.drainStderr() catch "";
            if (stderr.len > 0) {
                std.log.err("claude stderr: {s}", .{stderr});
            }
            std.log.err("claude exited with code {d}", .{exit_code});
        }

        // Drain remaining stdout
        const lines = proc.drainStdout() catch return null;

        // Find the result JSON line
        for (lines) |line| {
            if (parseClaudeResponse(self.allocator, line)) |text| {
                return .{ .text = text, .done = true };
            }
        }

        return .{ .text = "", .done = true };
    }

    return null;
}

fn cancelFn(ptr: *anyopaque, handle: Handle) void {
    const self: *Claude = @ptrCast(@alignCast(ptr));

    if (self.sessions.fetchRemove(handle)) |kv| {
        self.pool.kill(kv.value.process_id);
        self.pool.remove(kv.value.process_id);
        self.allocator.free(kv.value.conversation_id);
    }
}

fn deinitFn(ptr: *anyopaque) void {
    const self: *Claude = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn parseClaudeResponse(allocator: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(struct {
        result: ?[]const u8 = null,
        is_error: bool = false,
    }, allocator, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    if (parsed.value.is_error) return null;
    const result = parsed.value.result orelse return null;
    if (result.len == 0) return null;

    return allocator.dupe(u8, result) catch null;
}

// ─── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "buildPrompt concatenates messages" {
    const messages = &[_]msg.Message{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "hi there" },
    };
    const prompt = try buildPrompt(testing.allocator, messages);
    defer testing.allocator.free(prompt);

    try testing.expectEqualStrings("hello\nhi there\n", prompt);
}

test "buildPrompt empty messages" {
    const prompt = try buildPrompt(testing.allocator, &.{});
    defer testing.allocator.free(prompt);

    try testing.expectEqualStrings("", prompt);
}

test "buildPrompt single message" {
    const messages = &[_]msg.Message{
        .{ .role = .user, .content = "test" },
    };
    const prompt = try buildPrompt(testing.allocator, messages);
    defer testing.allocator.free(prompt);

    try testing.expectEqualStrings("test\n", prompt);
}

test "buildCmd new session (no resume)" {
    var cmd = try buildCmd(testing.allocator, "hello world", "abc-123", false, "");
    defer cmd.deinit();

    const argv = cmd.argv.items;
    try testing.expectEqual(8, argv.len);
    try testing.expectEqualStrings("claude", argv[0]);
    try testing.expectEqualStrings("-p", argv[1]);
    try testing.expectEqualStrings("hello world", argv[2]);
    try testing.expectEqualStrings("--output-format", argv[3]);
    try testing.expectEqualStrings("json", argv[4]);
    try testing.expectEqualStrings("--session-id", argv[5]);
    try testing.expectEqualStrings("abc-123", argv[6]);
    try testing.expectEqualStrings("--dangerously-skip-permissions", argv[7]);
}

test "buildCmd resumed session" {
    var cmd = try buildCmd(testing.allocator, "follow up", "abc-123", true, "");
    defer cmd.deinit();

    const argv = cmd.argv.items;
    try testing.expectEqual(8, argv.len);
    try testing.expectEqualStrings("claude", argv[0]);
    try testing.expectEqualStrings("-p", argv[1]);
    try testing.expectEqualStrings("follow up", argv[2]);
    try testing.expectEqualStrings("--output-format", argv[3]);
    try testing.expectEqualStrings("json", argv[4]);
    try testing.expectEqualStrings("--resume", argv[5]);
    try testing.expectEqualStrings("abc-123", argv[6]);
    try testing.expectEqualStrings("--dangerously-skip-permissions", argv[7]);
}

test "buildCmd with system prompt" {
    var cmd = try buildCmd(testing.allocator, "hello", "abc-123", false, "Be helpful");
    defer cmd.deinit();

    const argv = cmd.argv.items;
    try testing.expectEqual(10, argv.len);
    try testing.expectEqualStrings("claude", argv[0]);
    try testing.expectEqualStrings("-p", argv[1]);
    try testing.expectEqualStrings("hello", argv[2]);
    try testing.expectEqualStrings("--output-format", argv[3]);
    try testing.expectEqualStrings("json", argv[4]);
    try testing.expectEqualStrings("--system-prompt", argv[5]);
    try testing.expectEqualStrings("Be helpful", argv[6]);
    try testing.expectEqualStrings("--session-id", argv[7]);
    try testing.expectEqualStrings("abc-123", argv[8]);
    try testing.expectEqualStrings("--dangerously-skip-permissions", argv[9]);
}

test "parseClaudeResponse valid result" {
    const json =
        \\{"result":"Hello!","is_error":false}
    ;
    const text = parseClaudeResponse(testing.allocator, json) orelse
        return error.ExpectedResult;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Hello!", text);
}

test "parseClaudeResponse error response" {
    const json =
        \\{"result":"something","is_error":true}
    ;
    try testing.expect(parseClaudeResponse(testing.allocator, json) == null);
}

test "parseClaudeResponse null result" {
    const json =
        \\{"result":null,"is_error":false}
    ;
    try testing.expect(parseClaudeResponse(testing.allocator, json) == null);
}

test "parseClaudeResponse empty result" {
    const json =
        \\{"result":"","is_error":false}
    ;
    try testing.expect(parseClaudeResponse(testing.allocator, json) == null);
}

test "parseClaudeResponse malformed JSON" {
    try testing.expect(parseClaudeResponse(testing.allocator, "not json") == null);
    try testing.expect(parseClaudeResponse(testing.allocator, "") == null);
    try testing.expect(parseClaudeResponse(testing.allocator, "{}") == null);
}
