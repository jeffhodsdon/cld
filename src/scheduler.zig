const std = @import("std");
const Allocator = std.mem.Allocator;
const cron_lib = @import("cron");

// Extract the Datetime type from the Cron.next() signature to avoid
// importing the datetime module separately (which causes module conflicts).
const Datetime = @typeInfo(@TypeOf(cron_lib.Cron.next)).@"fn".params[1].type.?;

const Scheduler = @This();

pub const Schedule = union(enum) {
    cron: cron_lib.Cron,
    interval: u64, // every N seconds
    once: i64, // fire at this epoch second
};

pub const Task = struct {
    name: []const u8, // owned by Scheduler
    schedule: Schedule,
    last_run: i64, // epoch seconds, 0 = never
    one_shot: bool,
};

allocator: Allocator,
tasks: std.ArrayListUnmanaged(Task),
due_buf: std.ArrayListUnmanaged([]const u8),
deferred_free: std.ArrayListUnmanaged([]const u8), // names from removed one-shot tasks
state_path: ?[]const u8,

pub fn init(allocator: Allocator, state_path: ?[]const u8) Scheduler {
    return .{
        .allocator = allocator,
        .tasks = .empty,
        .due_buf = .empty,
        .deferred_free = .empty,
        .state_path = state_path,
    };
}

pub fn deinit(self: *Scheduler) void {
    for (self.deferred_free.items) |name| self.allocator.free(name);
    self.deferred_free.deinit(self.allocator);
    for (self.tasks.items) |task| {
        self.allocator.free(task.name);
    }
    self.tasks.deinit(self.allocator);
    self.due_buf.deinit(self.allocator);
}

/// Add a task with the given schedule. Duplicates the name.
pub fn add(self: *Scheduler, name: []const u8, schedule: Schedule, one_shot: bool) !void {
    const duped = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(duped);
    try self.tasks.append(self.allocator, .{
        .name = duped,
        .schedule = schedule,
        .last_run = 0,
        .one_shot = one_shot,
    });
}

/// Remove a task by name. Frees the name.
pub fn remove(self: *Scheduler, name: []const u8) void {
    var i: usize = 0;
    while (i < self.tasks.items.len) {
        if (std.mem.eql(u8, self.tasks.items[i].name, name)) {
            self.allocator.free(self.tasks.items[i].name);
            _ = self.tasks.swapRemove(i);
            return;
        }
        i += 1;
    }
}

/// Parse a cron expression into a Schedule.
pub fn parseCron(expr: []const u8) !Schedule {
    var c = cron_lib.Cron.init();
    try c.parse(expr);
    return .{ .cron = c };
}

/// Returns the next fire time (epoch seconds) for a task, or null if it cannot be computed.
fn nextFire(task: *Task, now_s: i64) ?i64 {
    switch (task.schedule) {
        .cron => |*c| {
            // Compute from last_run if set, otherwise from now minus 1 second
            // so that an immediate check can fire.
            const base_s = if (task.last_run > 0) task.last_run else now_s - 1;
            const base_dt = Datetime.fromTimestamp(base_s * std.time.ms_per_s);
            const next_dt = c.next(base_dt) catch return null;
            const next_ms: i128 = next_dt.toTimestamp();
            return @intCast(@divFloor(next_ms, std.time.ms_per_s));
        },
        .interval => |secs| {
            if (task.last_run == 0) return now_s; // fire immediately on first tick
            return task.last_run + @as(i64, @intCast(secs));
        },
        .once => |at| {
            if (task.last_run > 0) return null; // already fired
            return at;
        },
    }
}

/// Check all tasks and return names of those that are due.
/// Caller must not store the returned slice across tick() calls.
pub fn tick(self: *Scheduler, now_s: i64) []const []const u8 {
    // Free names from one-shot tasks removed in the previous tick
    for (self.deferred_free.items) |name| self.allocator.free(name);
    self.deferred_free.clearRetainingCapacity();
    self.due_buf.clearRetainingCapacity();

    var i: usize = 0;
    while (i < self.tasks.items.len) {
        var task = &self.tasks.items[i];
        const fire_at = nextFire(task, now_s) orelse {
            i += 1;
            continue;
        };

        if (fire_at <= now_s) {
            self.due_buf.append(self.allocator, task.name) catch {};
            task.last_run = now_s;

            if (task.one_shot) {
                // Defer freeing the name — due_buf still references it
                self.deferred_free.append(self.allocator, task.name) catch {};
                _ = self.tasks.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }

    return self.due_buf.items;
}

// ── Persistence ──────────────────────────────────────────────────────

/// Save last_run times to state_path as JSON.
pub fn save(self: *Scheduler) !void {
    const path = self.state_path orelse return;

    // Build JSON in memory, then write at once
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(self.allocator);

    try buf.appendSlice(self.allocator, "{\n");
    for (self.tasks.items, 0..) |task, idx| {
        try buf.appendSlice(self.allocator, "  \"");
        try buf.appendSlice(self.allocator, task.name);
        try buf.appendSlice(self.allocator, "\": ");
        var num_buf: [20]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{task.last_run}) catch "0";
        try buf.appendSlice(self.allocator, num);
        if (idx + 1 < self.tasks.items.len) try buf.append(self.allocator, ',');
        try buf.append(self.allocator, '\n');
    }
    try buf.appendSlice(self.allocator, "}\n");

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Load last_run times from state_path. Tasks must already be registered.
pub fn loadState(self: *Scheduler) !void {
    const path = self.state_path orelse return;
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    const bytes = try file.readToEndAlloc(self.allocator, 64 * 1024);
    defer self.allocator.free(bytes);

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        self.allocator,
        bytes,
        .{},
    ) catch return;
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            for (self.tasks.items) |*task| {
                if (obj.get(task.name)) |val| {
                    switch (val) {
                        .integer => |n| {
                            task.last_run = n;
                        },
                        else => {},
                    }
                }
            }
        },
        else => {},
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "tick returns due interval task" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("test_task", .{ .interval = 60 }, false);

    // First tick: interval tasks fire immediately when last_run == 0
    const due = s.tick(1000);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("test_task", due[0]);
}

test "tick does not return task that is not due" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("test_task", .{ .interval = 60 }, false);

    // Fire it
    _ = s.tick(1000);

    // 30 seconds later — not due yet
    const due = s.tick(1030);
    try std.testing.expectEqual(0, due.len);
}

test "interval task fires again after interval" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("test_task", .{ .interval = 60 }, false);

    _ = s.tick(1000); // fires, last_run = 1000
    const due = s.tick(1060); // 60s later, due again
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("test_task", due[0]);
}

test "one-shot task auto-removes after firing" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("once_task", .{ .once = 500 }, true);
    try std.testing.expectEqual(1, s.tasks.items.len);

    // Fire it
    const due = s.tick(500);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("once_task", due[0]);

    // Task should be removed
    try std.testing.expectEqual(0, s.tasks.items.len);
}

test "once task does not fire before its time" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("once_task", .{ .once = 500 }, true);

    const due = s.tick(499);
    try std.testing.expectEqual(0, due.len);
    try std.testing.expectEqual(1, s.tasks.items.len);
}

test "once task without one_shot does not re-fire" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("once_task", .{ .once = 500 }, false);

    // First tick at t=500 — fires
    const due1 = s.tick(500);
    try std.testing.expectEqual(1, due1.len);

    // Second tick — should NOT fire again
    const due2 = s.tick(600);
    try std.testing.expectEqual(0, due2.len);
}

test "cron schedule parsing and tick" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    // Every minute
    const schedule = try parseCron("* * * * *");
    try s.add("cron_task", schedule, false);

    // Use a known timestamp: 2024-01-01 00:00:00 UTC = 1704067200
    const due = s.tick(1704067200);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("cron_task", due[0]);
}

test "add and remove" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("a", .{ .interval = 10 }, false);
    try s.add("b", .{ .interval = 20 }, false);
    try std.testing.expectEqual(2, s.tasks.items.len);

    s.remove("a");
    try std.testing.expectEqual(1, s.tasks.items.len);
    try std.testing.expectEqualStrings("b", s.tasks.items[0].name);
}

test "save and loadState round-trip" {
    var s = Scheduler.init(std.testing.allocator, "/tmp/cld-scheduler-test.json");
    defer s.deinit();

    try s.add("task_a", .{ .interval = 60 }, false);
    try s.add("task_b", .{ .interval = 120 }, false);

    // Simulate firing
    _ = s.tick(5000);
    try s.save();

    // New scheduler, same tasks, load state
    var s2 = Scheduler.init(std.testing.allocator, "/tmp/cld-scheduler-test.json");
    defer s2.deinit();

    try s2.add("task_a", .{ .interval = 60 }, false);
    try s2.add("task_b", .{ .interval = 120 }, false);
    try s2.loadState();

    try std.testing.expectEqual(5000, s2.tasks.items[0].last_run);
    try std.testing.expectEqual(5000, s2.tasks.items[1].last_run);

    // Clean up
    std.fs.cwd().deleteFile("/tmp/cld-scheduler-test.json") catch {};
}
