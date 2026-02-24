const std = @import("std");
const Provider = @import("provider").Provider;
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

const QueuedMessage = struct {
    prompt: []const u8,
    system_prompt: []const u8,
    conversation_id: []const u8,
};

allocator: std.mem.Allocator,
pool: *ProcessPool,
sessions: std.AutoHashMap(Handle, SessionInfo),
/// Maps conversation_id → session_uuid for reuse across messages.
conversation_uuids: std.StringHashMap([]const u8),
/// FIFO message queue — processed one at a time per conversation.
queue: std.ArrayListUnmanaged(QueuedMessage),
next_handle: u64,

pub fn init(allocator: std.mem.Allocator, pool: *ProcessPool) Claude {
    return Claude{
        .allocator = allocator,
        .pool = pool,
        .sessions = std.AutoHashMap(Handle, SessionInfo).init(allocator),
        .conversation_uuids = std.StringHashMap([]const u8).init(allocator),
        .queue = .empty,
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

    // Free queued messages
    for (self.queue.items) |i| {
        self.allocator.free(i.prompt);
        self.allocator.free(i.system_prompt);
        self.allocator.free(i.conversation_id);
    }
    self.queue.deinit(self.allocator);

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
        for (m.attachments) |path| {
            try buf.appendSlice(allocator, "[Attachment: ");
            try buf.appendSlice(allocator, path);
            try buf.appendSlice(allocator, "]\n");
        }
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

    // Enqueue the message; processQueue will spawn when the conversation is free.
    const prompt = buildPrompt(self.allocator, req.messages) catch return handle;
    const conv_id = self.allocator.dupe(u8, req.conversation_id) catch {
        self.allocator.free(prompt);
        return handle;
    };
    const sys = self.allocator.dupe(u8, req.system_prompt) catch {
        self.allocator.free(prompt);
        self.allocator.free(conv_id);
        return handle;
    };

    self.queue.append(self.allocator, .{
        .prompt = prompt,
        .system_prompt = sys,
        .conversation_id = conv_id,
    }) catch {
        self.allocator.free(prompt);
        self.allocator.free(conv_id);
        self.allocator.free(sys);
        return handle;
    };

    self.processQueue();
    return handle;
}

fn hasActiveSession(self: *Claude, conversation_id: []const u8) bool {
    var it = self.sessions.valueIterator();
    while (it.next()) |session| {
        if (std.mem.eql(u8, session.conversation_id, conversation_id)) return true;
    }
    return false;
}

/// Dequeue and spawn one message per conversation that has no active session.
fn processQueue(self: *Claude) void {
    var i: usize = 0;
    while (i < self.queue.items.len) {
        const q = self.queue.items[i];

        if (self.hasActiveSession(q.conversation_id)) {
            i += 1;
            continue;
        }

        // Remove from queue (order-preserving)
        _ = self.queue.orderedRemove(i);

        // Ensure conversation UUID exists
        const existing = self.conversation_uuids.get(q.conversation_id);
        const is_resume = existing != null;
        const session_uuid = existing orelse blk: {
            const uuid = Uuid.v4();
            const uuid_str = uuid.toStrAlloc(self.allocator) catch {
                self.freeQueued(q);
                continue;
            };
            const key = self.allocator.dupe(u8, q.conversation_id) catch {
                self.allocator.free(uuid_str);
                self.freeQueued(q);
                continue;
            };
            self.conversation_uuids.put(key, uuid_str) catch {
                self.allocator.free(uuid_str);
                self.allocator.free(key);
                self.freeQueued(q);
                continue;
            };
            break :blk uuid_str;
        };

        var cmd = buildCmd(self.allocator, q.prompt, session_uuid, is_resume, q.system_prompt) catch {
            self.freeQueued(q);
            continue;
        };
        defer cmd.deinit();

        const process_id = self.pool.spawn(&cmd, .{ .stderr = .pipe }) catch {
            self.freeQueued(q);
            continue;
        };

        const new_handle = self.next_handle;
        self.next_handle += 1;

        // conversation_id transfers ownership to the session
        self.sessions.put(new_handle, .{
            .process_id = process_id,
            .session_uuid = session_uuid,
            .conversation_id = q.conversation_id,
        }) catch {
            self.pool.kill(process_id);
            self.pool.remove(process_id);
            self.freeQueued(q);
            continue;
        };

        std.log.info("processing [{s}] ({s})", .{
            q.conversation_id,
            if (is_resume) "resume" else "new session",
        });
        if (std.mem.indexOf(u8, q.prompt, "[Attachment:") != null) {
            std.log.info("prompt contains attachment refs: {s}", .{q.prompt});
        }

        // prompt and system_prompt are no longer needed
        self.allocator.free(q.prompt);
        self.allocator.free(q.system_prompt);
    }
}

fn freeQueued(self: *Claude, q: QueuedMessage) void {
    self.allocator.free(q.prompt);
    self.allocator.free(q.system_prompt);
    self.allocator.free(q.conversation_id);
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

            // Remove stale session UUID so next message starts a fresh session
            if (self.conversation_uuids.fetchRemove(session.conversation_id)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
                std.log.info("cleared stale session for [{s}]", .{session.conversation_id});
            }
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

    // Process next queued message for this (now-free) conversation
    self.processQueue();
}

fn deinitFn(ptr: *anyopaque) void {
    const self: *Claude = @ptrCast(@alignCast(ptr));
    self.deinit();
}

const ServerToolUse = struct {
    web_search_requests: ?u64 = null,
    web_fetch_requests: ?u64 = null,
};

const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
    server_tool_use: ?ServerToolUse = null,
};

const ModelUsageEntry = struct {
    inputTokens: ?u64 = null,
    outputTokens: ?u64 = null,
    cacheReadInputTokens: ?u64 = null,
    contextWindow: ?u64 = null,
    maxOutputTokens: ?u64 = null,
};

const ClaudeJson = struct {
    result: ?[]const u8 = null,
    is_error: bool = false,
    session_id: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    duration_api_ms: ?u64 = null,
    num_turns: ?u64 = null,
    total_cost_usd: ?f64 = null,
    usage: ?Usage = null,
    modelUsage: ?std.json.Value = null,
};

fn parseClaudeResponse(allocator: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(ClaudeJson, allocator, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const v = parsed.value;

    if (v.is_error) return null;

    // Log metadata
    if (v.total_cost_usd) |_| {
        const usage = v.usage orelse Usage{};
        const in = usage.input_tokens orelse 0;
        const out = usage.output_tokens orelse 0;
        const cache_read = usage.cache_read_input_tokens orelse 0;
        const cache_create = usage.cache_creation_input_tokens orelse 0;
        const total_tokens = in + out + cache_read + cache_create;

        // Extract context window and model name from modelUsage (first entry)
        var context_window: u64 = 0;
        var model_name: []const u8 = "unknown";
        if (v.modelUsage) |mu| {
            if (mu == .object) {
                var it = mu.object.iterator();
                if (it.next()) |entry| {
                    model_name = entry.key_ptr.*;
                    const model_parsed = std.json.parseFromValue(ModelUsageEntry, allocator, entry.value_ptr.*, .{ .ignore_unknown_fields = true }) catch null;
                    if (model_parsed) |mp| {
                        context_window = mp.value.contextWindow orelse 0;
                    }
                }
            }
        }

        const web_searches = if (usage.server_tool_use) |stu| stu.web_search_requests orelse 0 else 0;

        if (context_window > 0) {
            const total_k = total_tokens / 1000;
            const ctx_k = context_window / 1000;
            const pct = (total_tokens * 100) / context_window;
            std.log.info("claude: {s} | {d}ms | turns={d} | ctx={d}k/{d}k ({d}%) | web_searches={d}", .{
                model_name,
                v.duration_ms orelse 0,
                v.num_turns orelse 0,
                total_k,
                ctx_k,
                pct,
                web_searches,
            });
        } else {
            std.log.info("claude: {s} | {d}ms | turns={d} | tokens={d} | web_searches={d}", .{
                model_name,
                v.duration_ms orelse 0,
                v.num_turns orelse 0,
                total_tokens,
                web_searches,
            });
        }
    }

    const result = v.result orelse return null;
    const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
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

test "buildPrompt with attachments" {
    const paths = &[_][]const u8{"/tmp/photo.jpg"};
    const messages = &[_]msg.Message{
        .{ .role = .user, .content = "check this", .attachments = paths },
    };
    const prompt = try buildPrompt(testing.allocator, messages);
    defer testing.allocator.free(prompt);

    try testing.expectEqualStrings("check this\n[Attachment: /tmp/photo.jpg]\n", prompt);
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

test "parseClaudeResponse trims whitespace" {
    const json =
        \\{"result":"\n\nHello!\n\n","is_error":false}
    ;
    const text = parseClaudeResponse(testing.allocator, json) orelse
        return error.ExpectedResult;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Hello!", text);
}

test "message queued when conversation has active session" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();
    var claude = Claude.init(testing.allocator, &pool);
    defer claude.deinit();

    // Spawn a real process to act as the active session
    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");
    const pid = try pool.spawn(&cmd, .{});

    // Register it as an active session for "conv-1"
    const conv_id = try testing.allocator.dupe(u8, "conv-1");
    try claude.sessions.put(0, .{
        .process_id = pid,
        .session_uuid = "fake-uuid",
        .conversation_id = conv_id,
    });

    // Start a message for the same conversation
    _ = claude.provider().start(.{
        .conversation_id = "conv-1",
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .system_prompt = "",
    });

    // Message should be queued, not spawned
    try testing.expectEqual(@as(usize, 1), claude.queue.items.len);
    try testing.expectEqualStrings("conv-1", claude.queue.items[0].conversation_id);
    try testing.expectEqualStrings("hello\n", claude.queue.items[0].prompt);
}

test "multiple messages queued in order" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();
    var claude = Claude.init(testing.allocator, &pool);
    defer claude.deinit();

    // Spawn a real process as active session
    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");
    const pid = try pool.spawn(&cmd, .{});

    const conv_id = try testing.allocator.dupe(u8, "conv-1");
    try claude.sessions.put(0, .{
        .process_id = pid,
        .session_uuid = "fake-uuid",
        .conversation_id = conv_id,
    });

    // Queue two messages
    _ = claude.provider().start(.{
        .conversation_id = "conv-1",
        .messages = &.{.{ .role = .user, .content = "first" }},
        .system_prompt = "",
    });
    _ = claude.provider().start(.{
        .conversation_id = "conv-1",
        .messages = &.{.{ .role = .user, .content = "second" }},
        .system_prompt = "",
    });

    // Both queued in FIFO order
    try testing.expectEqual(@as(usize, 2), claude.queue.items.len);
    try testing.expectEqualStrings("first\n", claude.queue.items[0].prompt);
    try testing.expectEqualStrings("second\n", claude.queue.items[1].prompt);
}

test "hasActiveSession" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();
    var claude = Claude.init(testing.allocator, &pool);
    defer claude.deinit();

    try testing.expect(!claude.hasActiveSession("conv-1"));

    // Add an active session
    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");
    const pid = try pool.spawn(&cmd, .{});

    const conv_id = try testing.allocator.dupe(u8, "conv-1");
    try claude.sessions.put(0, .{
        .process_id = pid,
        .session_uuid = "fake-uuid",
        .conversation_id = conv_id,
    });

    try testing.expect(claude.hasActiveSession("conv-1"));
    try testing.expect(!claude.hasActiveSession("conv-2"));
}

test "different conversations not blocked by each other" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();
    var claude = Claude.init(testing.allocator, &pool);
    defer claude.deinit();

    // Active session for conv-1
    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");
    const pid = try pool.spawn(&cmd, .{});

    const conv_id = try testing.allocator.dupe(u8, "conv-1");
    try claude.sessions.put(0, .{
        .process_id = pid,
        .session_uuid = "fake-uuid",
        .conversation_id = conv_id,
    });

    // Message for conv-1 should be queued
    _ = claude.provider().start(.{
        .conversation_id = "conv-1",
        .messages = &.{.{ .role = .user, .content = "blocked" }},
        .system_prompt = "",
    });
    try testing.expectEqual(@as(usize, 1), claude.queue.items.len);

    // conv-2 has no active session — processQueue will try to spawn "claude"
    // which will fail, but the message should NOT remain in the queue
    _ = claude.provider().start(.{
        .conversation_id = "conv-2",
        .messages = &.{.{ .role = .user, .content = "free" }},
        .system_prompt = "",
    });

    // conv-2 message was dequeued (processQueue attempted it)
    // conv-1 message still queued
    try testing.expectEqual(@as(usize, 1), claude.queue.items.len);
    try testing.expectEqualStrings("conv-1", claude.queue.items[0].conversation_id);
}

