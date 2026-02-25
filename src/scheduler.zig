const std = @import("std");
const Allocator = std.mem.Allocator;

const Scheduler = @This();

// libc types for localtime_r
const Tm = extern struct {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
    tm_gmtoff: i64,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const isize, result: *Tm) ?*Tm;

// ── Built-in Cron ────────────────────────────────────────────────────

pub const Cron = struct {
    minutes: u64, // bits 0..59
    hours: u32, // bits 0..23
    days_of_month: u32, // bits 1..31
    months: u16, // bits 1..12
    days_of_week: u8, // bits 0..6 (0=Sun)

    pub const ParseError = error{
        InvalidExpression,
        InvalidValue,
    };

    pub fn parse(expr: []const u8) ParseError!Cron {
        var result = Cron{
            .minutes = 0,
            .hours = 0,
            .days_of_month = 0,
            .months = 0,
            .days_of_week = 0,
        };

        var field_idx: usize = 0;
        var it = std.mem.tokenizeScalar(u8, expr, ' ');
        while (it.next()) |field| {
            if (field_idx >= 5) return error.InvalidExpression;
            switch (field_idx) {
                0 => result.minutes = parseField(u64, field, 0, 59) orelse return error.InvalidValue,
                1 => result.hours = parseField(u32, field, 0, 23) orelse return error.InvalidValue,
                2 => result.days_of_month = parseField(u32, field, 1, 31) orelse return error.InvalidValue,
                3 => result.months = parseField(u16, field, 1, 12) orelse return error.InvalidValue,
                4 => result.days_of_week = parseField(u8, field, 0, 6) orelse return error.InvalidValue,
                else => unreachable,
            }
            field_idx += 1;
        }
        if (field_idx != 5) return error.InvalidExpression;
        return result;
    }

    fn parseField(comptime T: type, field: []const u8, min: u6, max: u6) ?T {
        var bits: T = 0;
        var list_it = std.mem.tokenizeScalar(u8, field, ',');
        while (list_it.next()) |item| {
            bits |= parseItem(T, item, min, max) orelse return null;
        }
        return bits;
    }

    fn parseItem(comptime T: type, item: []const u8, min: u6, max: u6) ?T {
        // Split on '/' for step
        var step: u8 = 1;
        var range_part = item;
        if (std.mem.indexOfScalar(u8, item, '/')) |slash| {
            step = parseNum(item[slash + 1 ..]) orelse return null;
            if (step == 0) return null;
            range_part = item[0..slash];
        }

        var lo: u8 = min;
        var hi: u8 = max;

        if (std.mem.eql(u8, range_part, "*")) {
            // lo/hi already set to full range
        } else if (std.mem.indexOfScalar(u8, range_part, '-')) |dash| {
            lo = parseNum(range_part[0..dash]) orelse return null;
            hi = parseNum(range_part[dash + 1 ..]) orelse return null;
            if (lo < min or hi > max or lo > hi) return null;
        } else {
            // Single value
            lo = parseNum(range_part) orelse return null;
            if (lo < min or lo > max) return null;
            if (step == 1) {
                return @as(T, 1) << @intCast(lo);
            }
            hi = max;
        }

        var bits: T = 0;
        var v: u8 = lo;
        while (v <= hi) : (v += step) {
            bits |= @as(T, 1) << @intCast(v);
            if (v > hi -| step and v != hi) break;
        }
        return bits;
    }

    fn parseNum(s: []const u8) ?u8 {
        if (s.len == 0) return null;
        return std.fmt.parseInt(u8, s, 10) catch null;
    }

    pub fn matches(self: Cron, epoch_s: i64) bool {
        var tm: Tm = undefined;
        const ts: isize = @intCast(epoch_s);
        _ = localtime_r(&ts, &tm);

        const minute: u6 = @intCast(tm.tm_min);
        const hour: u5 = @intCast(tm.tm_hour);
        const mday: u5 = @intCast(tm.tm_mday);
        const month: u4 = @intCast(tm.tm_mon + 1); // tm_mon is 0-based
        const wday: u3 = @intCast(tm.tm_wday);

        return (self.minutes & (@as(u64, 1) << minute) != 0) and
            (self.hours & (@as(u32, 1) << hour) != 0) and
            (self.days_of_month & (@as(u32, 1) << mday) != 0) and
            (self.months & (@as(u16, 1) << month) != 0) and
            (self.days_of_week & (@as(u8, 1) << wday) != 0);
    }
};

// ── Schedule / Task ──────────────────────────────────────────────────

pub const Schedule = union(enum) {
    cron: Cron,
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
    const c = try Cron.parse(expr);
    return .{ .cron = c };
}

/// Returns the next fire time (epoch seconds) for a task, or null if not due.
fn nextFire(task: *Task, now_s: i64) ?i64 {
    switch (task.schedule) {
        .cron => |c| {
            if (!c.matches(now_s)) return null;
            // Don't fire twice in the same minute
            const now_min = @divFloor(now_s, 60);
            const last_min = @divFloor(task.last_run, 60);
            if (now_min == last_min) return null;
            return now_s;
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

test "Cron.parse wildcard" {
    const c = try Cron.parse("* * * * *");
    try std.testing.expectEqual(@as(u64, (@as(u64, 1) << 60) - 1), c.minutes);
    try std.testing.expectEqual(@as(u32, (@as(u32, 1) << 24) - 1), c.hours);
    // bits 1..31: all bits set except bit 0 = 0xFFFFFFFE
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFE), c.days_of_month);
    // bits 1..12: 0x1FFE
    try std.testing.expectEqual(@as(u16, 0x1FFE), c.months);
    try std.testing.expectEqual(@as(u8, (@as(u8, 1) << 7) - 1), c.days_of_week);
}

test "Cron.parse specific values" {
    const c = try Cron.parse("30 2 15 6 3");
    try std.testing.expectEqual(@as(u64, 1) << 30, c.minutes);
    try std.testing.expectEqual(@as(u32, 1) << 2, c.hours);
    try std.testing.expectEqual(@as(u32, 1) << 15, c.days_of_month);
    try std.testing.expectEqual(@as(u16, 1) << 6, c.months);
    try std.testing.expectEqual(@as(u8, 1) << 3, c.days_of_week);
}

test "Cron.parse range" {
    const c = try Cron.parse("1-5 * * * *");
    const expected: u64 = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5);
    try std.testing.expectEqual(expected, c.minutes);
}

test "Cron.parse step" {
    const c = try Cron.parse("*/15 * * * *");
    const expected: u64 = (1 << 0) | (1 << 15) | (1 << 30) | (1 << 45);
    try std.testing.expectEqual(expected, c.minutes);
}

test "Cron.parse list" {
    const c = try Cron.parse("0,30 * * * *");
    const expected: u64 = (1 << 0) | (1 << 30);
    try std.testing.expectEqual(expected, c.minutes);
}

test "Cron.parse range with step" {
    const c = try Cron.parse("1-10/3 * * * *");
    const expected: u64 = (1 << 1) | (1 << 4) | (1 << 7) | (1 << 10);
    try std.testing.expectEqual(expected, c.minutes);
}

test "Cron.parse midnight compact" {
    const c = try Cron.parse("1 0 * * *");
    try std.testing.expectEqual(@as(u64, 1) << 1, c.minutes);
    try std.testing.expectEqual(@as(u32, 1) << 0, c.hours);
}

test "Cron.parse rejects invalid" {
    try std.testing.expectError(error.InvalidExpression, Cron.parse("* * *"));
    try std.testing.expectError(error.InvalidValue, Cron.parse("60 * * * *"));
    try std.testing.expectError(error.InvalidValue, Cron.parse("* 25 * * *"));
    try std.testing.expectError(error.InvalidExpression, Cron.parse("* * * * * *"));
}

test "Cron.matches with localtime" {
    const epoch: i64 = 1704067200; // 2024-01-01 00:00:00 UTC
    var tm: Tm = undefined;
    const ts: isize = @intCast(epoch);
    _ = localtime_r(&ts, &tm);

    var min_buf: [8]u8 = undefined;
    var hour_buf: [8]u8 = undefined;
    var mday_buf: [8]u8 = undefined;
    var mon_buf: [8]u8 = undefined;

    const min_str = std.fmt.bufPrint(&min_buf, "{d}", .{tm.tm_min}) catch unreachable;
    const hour_str = std.fmt.bufPrint(&hour_buf, "{d}", .{tm.tm_hour}) catch unreachable;
    const mday_str = std.fmt.bufPrint(&mday_buf, "{d}", .{tm.tm_mday}) catch unreachable;
    const mon_str = std.fmt.bufPrint(&mon_buf, "{d}", .{tm.tm_mon + 1}) catch unreachable;

    var expr_buf: [64]u8 = undefined;
    const expr = std.fmt.bufPrint(&expr_buf, "{s} {s} {s} {s} *", .{ min_str, hour_str, mday_str, mon_str }) catch unreachable;

    const c = try Cron.parse(expr);
    try std.testing.expect(c.matches(epoch));
}

test "tick returns due interval task" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("test_task", .{ .interval = 60 }, false);

    const due = s.tick(1000);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("test_task", due[0]);
}

test "tick does not return task that is not due" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("test_task", .{ .interval = 60 }, false);
    _ = s.tick(1000);

    const due = s.tick(1030);
    try std.testing.expectEqual(0, due.len);
}

test "interval task fires again after interval" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("test_task", .{ .interval = 60 }, false);

    _ = s.tick(1000);
    const due = s.tick(1060);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("test_task", due[0]);
}

test "one-shot task auto-removes after firing" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    try s.add("once_task", .{ .once = 500 }, true);
    try std.testing.expectEqual(1, s.tasks.items.len);

    const due = s.tick(500);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("once_task", due[0]);
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

    const due1 = s.tick(500);
    try std.testing.expectEqual(1, due1.len);

    const due2 = s.tick(600);
    try std.testing.expectEqual(0, due2.len);
}

test "cron schedule parsing and tick" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    const schedule = try parseCron("* * * * *");
    try s.add("cron_task", schedule, false);

    const due = s.tick(1704067200);
    try std.testing.expectEqual(1, due.len);
    try std.testing.expectEqualStrings("cron_task", due[0]);
}

test "cron does not fire twice in same minute" {
    var s = Scheduler.init(std.testing.allocator, null);
    defer s.deinit();

    const schedule = try parseCron("* * * * *");
    try s.add("cron_task", schedule, false);

    const due1 = s.tick(1704067200);
    try std.testing.expectEqual(1, due1.len);

    // 30 seconds later, same minute
    const due2 = s.tick(1704067230);
    try std.testing.expectEqual(0, due2.len);

    // Next minute
    const due3 = s.tick(1704067260);
    try std.testing.expectEqual(1, due3.len);
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

    _ = s.tick(5000);
    try s.save();

    var s2 = Scheduler.init(std.testing.allocator, "/tmp/cld-scheduler-test.json");
    defer s2.deinit();

    try s2.add("task_a", .{ .interval = 60 }, false);
    try s2.add("task_b", .{ .interval = 120 }, false);
    try s2.loadState();

    try std.testing.expectEqual(5000, s2.tasks.items[0].last_run);
    try std.testing.expectEqual(5000, s2.tasks.items[1].last_run);

    std.fs.cwd().deleteFile("/tmp/cld-scheduler-test.json") catch {};
}
