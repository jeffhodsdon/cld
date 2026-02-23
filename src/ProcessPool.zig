const std = @import("std");
const posix = std.posix;
const Cmd = @import("Cmd");
const Process = @import("Process");

const ProcessPool = @This();

pub const Id = u64;

pub const Event = struct {
    id: Id,
    tag: Tag,

    pub const Tag = enum {
        stdout_ready,
        stderr_ready,
        exited,
    };
};

pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

const MAX_FDS = 128;

processes: std.AutoHashMap(Id, *Process),
next_id: Id,
allocator: std.mem.Allocator,
events_buf: std.ArrayListUnmanaged(Event),
signal_fd: ?posix.fd_t = null,

pub fn init(allocator: std.mem.Allocator) ProcessPool {
    return .{
        .processes = std.AutoHashMap(Id, *Process).init(allocator),
        .next_id = 1,
        .allocator = allocator,
        .events_buf = .empty,
    };
}

/// Set a file descriptor (read end of a pipe) that wakes poll() on signal.
pub fn setSignalFd(self: *ProcessPool, fd: posix.fd_t) void {
    self.signal_fd = fd;
}

pub fn deinit(self: *ProcessPool) void {
    var it = self.processes.valueIterator();
    while (it.next()) |proc_ptr| {
        proc_ptr.*.deinit();
        self.allocator.destroy(proc_ptr.*);
    }
    self.processes.deinit();
    self.events_buf.deinit(self.allocator);
}

pub fn spawn(self: *ProcessPool, cmd: *Cmd, opts: Process.SpawnOptions) !Id {
    const proc = try self.allocator.create(Process);
    errdefer self.allocator.destroy(proc);

    proc.* = try Process.spawn(self.allocator, cmd, opts);

    const id = self.next_id;
    self.next_id += 1;
    try self.processes.put(id, proc);
    return id;
}

pub fn get(self: *ProcessPool, id: Id) ?*Process {
    return self.processes.get(id);
}

pub fn remove(self: *ProcessPool, id: Id) void {
    if (self.processes.fetchRemove(id)) |kv| {
        kv.value.deinit();
        self.allocator.destroy(kv.value);
    }
}

pub fn kill(self: *ProcessPool, id: Id) void {
    if (self.processes.get(id)) |proc| {
        proc.kill();
    }
}

/// Poll all tracked processes for I/O readiness and exits.
/// Returns a slice of events valid until the next call to poll().
pub fn poll(self: *ProcessPool, timeout_ms: i32) ![]const Event {
    self.events_buf.clearRetainingCapacity();

    // Build pollfd array on stack
    var fds: [MAX_FDS]std.c.pollfd = undefined;
    var fd_map: [MAX_FDS]struct { id: Id, is_stderr: bool } = undefined;
    var n_fds: usize = 0;

    var it = self.processes.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const proc = entry.value_ptr.*;

        if (proc.stdoutFd()) |fd| {
            if (n_fds < MAX_FDS) {
                fds[n_fds] = .{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 };
                fd_map[n_fds] = .{ .id = id, .is_stderr = false };
                n_fds += 1;
            }
        }
        if (proc.stderrFd()) |fd| {
            if (n_fds < MAX_FDS) {
                fds[n_fds] = .{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 };
                fd_map[n_fds] = .{ .id = id, .is_stderr = true };
                n_fds += 1;
            }
        }
    }

    // Add signal pipe fd if set (for waking poll on SIGINT/SIGTERM)
    const signal_fd_idx: ?usize = if (self.signal_fd) |sfd| blk: {
        if (n_fds < MAX_FDS) {
            const idx = n_fds;
            fds[n_fds] = .{ .fd = sfd, .events = std.c.POLL.IN, .revents = 0 };
            n_fds += 1;
            break :blk idx;
        }
        break :blk null;
    } else null;

    // Poll
    if (n_fds > 0) {
        _ = try posix.poll(fds[0..n_fds], timeout_ms);
    } else {
        if (timeout_ms > 0) {
            std.Thread.sleep(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
        }
    }

    // Drain signal pipe if it was signaled
    if (signal_fd_idx) |idx| {
        const revents: u16 = @bitCast(fds[idx].revents);
        if (revents & std.c.POLL.IN != 0) {
            var buf: [1]u8 = undefined;
            _ = posix.read(self.signal_fd.?, &buf) catch {};
        }
    }

    // Check for readable fds (skip signal fd)
    const process_fds = if (signal_fd_idx) |idx| idx else n_fds;
    for (0..process_fds) |i| {
        const revents: u16 = @bitCast(fds[i].revents);
        const mask: u16 = std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR;
        if (revents & mask != 0) {
            try self.events_buf.append(self.allocator, .{
                .id = fd_map[i].id,
                .tag = if (fd_map[i].is_stderr) .stderr_ready else .stdout_ready,
            });
        }
    }

    // Check for exits via waitpid on each process
    var exit_it = self.processes.iterator();
    while (exit_it.next()) |entry| {
        const id = entry.key_ptr.*;
        const proc = entry.value_ptr.*;
        if (proc.checkExit()) |_| {
            try self.events_buf.append(self.allocator, .{ .id = id, .tag = .exited });
        }
    }

    return self.events_buf.items;
}

/// Synchronous exec: spawn, wait, collect output. Not tracked in pool.
pub fn exec(allocator: std.mem.Allocator, cmd: *Cmd) !ExecResult {
    var env_map = try cmd.buildEnvMap(allocator);
    defer if (env_map) |*em| em.deinit();

    var child = std.process.Child.init(cmd.argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (cmd.cwd) |cwd| {
        child.cwd = cwd;
    }
    if (env_map) |*em| {
        child.env_map = em;
    }

    try child.spawn();

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr.deinit(allocator);

    child.collectOutput(allocator, &stdout, &stderr, 10 * 1024 * 1024) catch {};
    const term = try child.wait();

    const exit_code: u32 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing = std.testing;

test "spawn and get" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();

    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");

    const id = try pool.spawn(&cmd, .{});
    try testing.expect(pool.get(id) != null);
}

test "remove cleans up" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();

    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");

    const id = try pool.spawn(&cmd, .{});
    pool.remove(id);
    try testing.expect(pool.get(id) == null);
}

test "exec captures stdout" {
    var cmd = Cmd.init(testing.allocator, "/bin/echo");
    defer cmd.deinit();
    try cmd.arg("hello exec");

    var result = try ProcessPool.exec(testing.allocator, &cmd);
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello exec") != null);
    try testing.expectEqual(@as(u32, 0), result.exit_code);
}

test "exec captures exit code" {
    var cmd = Cmd.init(testing.allocator, "/usr/bin/false");
    defer cmd.deinit();

    var result = try ProcessPool.exec(testing.allocator, &cmd);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.exit_code);
}

test "poll returns exited event" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();

    var cmd = Cmd.init(testing.allocator, "/usr/bin/true");
    defer cmd.deinit();

    const id = try pool.spawn(&cmd, .{});

    // Wait for exit
    for (0..50) |_| {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        const events = try pool.poll(0);
        for (events) |ev| {
            if (ev.id == id and ev.tag == .exited) {
                return; // success
            }
        }
    }
    return error.TestUnexpectedResult;
}

test "multiple processes tracked" {
    var pool = ProcessPool.init(testing.allocator);
    defer pool.deinit();

    var cmd1 = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd1.deinit();
    try cmd1.arg("60");

    var cmd2 = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd2.deinit();
    try cmd2.arg("60");

    const id1 = try pool.spawn(&cmd1, .{});
    const id2 = try pool.spawn(&cmd2, .{});

    try testing.expect(id1 != id2);
    try testing.expect(pool.get(id1) != null);
    try testing.expect(pool.get(id2) != null);
}
