const std = @import("std");
const posix = std.posix;
const Cmd = @import("Cmd");

const Process = @This();

child: std.process.Child,
env_map: ?std.process.EnvMap,
allocator: std.mem.Allocator,
stdout_buf: std.ArrayListUnmanaged(u8),
stderr_buf: std.ArrayListUnmanaged(u8),
lines: std.ArrayListUnmanaged([]const u8),
exit_status: ?u32,

pub const SpawnOptions = struct {
    stdout: enum { pipe, ignore } = .pipe,
    stderr: enum { pipe, ignore } = .pipe,
};

pub fn spawn(allocator: std.mem.Allocator, cmd: *Cmd, opts: SpawnOptions) !Process {
    var env_map = try cmd.buildEnvMap(allocator);

    var child = std.process.Child.init(cmd.argv.items, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = switch (opts.stdout) {
        .pipe => .Pipe,
        .ignore => .Ignore,
    };
    child.stderr_behavior = switch (opts.stderr) {
        .pipe => .Pipe,
        .ignore => .Ignore,
    };
    if (cmd.cwd) |cwd| {
        child.cwd = cwd;
    }
    if (env_map) |*em| {
        child.env_map = em;
    }

    try child.spawn();

    // Set stdout/stderr to non-blocking
    if (child.stdout) |stdout| {
        setNonBlock(stdout.handle);
    }
    if (child.stderr) |stderr| {
        setNonBlock(stderr.handle);
    }

    return .{
        .child = child,
        .env_map = env_map,
        .allocator = allocator,
        .stdout_buf = .empty,
        .stderr_buf = .empty,
        .lines = .empty,
        .exit_status = null,
    };
}

fn setNonBlock(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, std.c.F.GETFL, 0) catch return;
    const nonblock: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    _ = posix.fcntl(fd, std.c.F.SETFL, flags | @as(usize, nonblock)) catch {};
}

pub fn stdoutFd(self: *const Process) ?posix.fd_t {
    const stdout = self.child.stdout orelse return null;
    return stdout.handle;
}

pub fn stderrFd(self: *const Process) ?posix.fd_t {
    const stderr = self.child.stderr orelse return null;
    return stderr.handle;
}

/// Read available pipe data into internal buffers without extracting lines.
/// Call this on stdout_ready/stderr_ready events to prevent pipe buffer from
/// filling up and blocking the child process.
pub fn drainPipe(self: *Process) void {
    if (self.stdoutFd()) |fd| {
        readAvailable(fd, &self.stdout_buf, self.allocator) catch {};
    }
    if (self.stderrFd()) |fd| {
        readAvailable(fd, &self.stderr_buf, self.allocator) catch {};
    }
}

/// Read available data from stdout and return completed lines.
/// The returned slice is valid until the next call to drainStdout.
pub fn drainStdout(self: *Process) ![]const []const u8 {
    // Free previous line dupes
    for (self.lines.items) |line| {
        self.allocator.free(line);
    }
    self.lines.clearRetainingCapacity();

    const fd = self.stdoutFd() orelse return self.lines.items;
    try readAvailable(fd, &self.stdout_buf, self.allocator);

    // Extract complete lines — dupe each line since buffer shifts invalidate slices
    while (std.mem.indexOfScalar(u8, self.stdout_buf.items, '\n')) |nl| {
        const line = try self.allocator.dupe(u8, self.stdout_buf.items[0..nl]);
        try self.lines.append(self.allocator, line);
        const after = nl + 1;
        std.mem.copyForwards(u8, self.stdout_buf.items[0..], self.stdout_buf.items[after..]);
        self.stdout_buf.items.len -= after;
    }

    return self.lines.items;
}

/// Read available data from stderr and return raw bytes.
/// The returned slice is valid until the next call to drainStderr.
pub fn drainStderr(self: *Process) ![]const u8 {
    const fd = self.stderrFd() orelse return "";
    try readAvailable(fd, &self.stderr_buf, self.allocator);
    return self.stderr_buf.items;
}

/// Clear the stderr buffer after processing.
pub fn clearStderr(self: *Process) void {
    self.stderr_buf.clearRetainingCapacity();
}

/// Non-blocking waitpid. Returns exit code if process has exited.
pub fn checkExit(self: *Process) ?u32 {
    if (self.exit_status) |es| return es;

    const result = posix.waitpid(self.child.id, std.c.W.NOHANG);
    if (result.pid == 0) {
        return null;
    }

    const status = result.status;
    if (std.c.W.IFEXITED(status)) {
        self.exit_status = std.c.W.EXITSTATUS(status);
    } else {
        self.exit_status = 255;
    }
    return self.exit_status;
}

pub fn kill(self: *Process) void {
    posix.kill(self.child.id, posix.SIG.TERM) catch {};
}

pub fn deinit(self: *Process) void {
    if (self.exit_status == null) {
        // SIGTERM first — give the child a chance to clean up its own subprocesses.
        posix.kill(self.child.id, posix.SIG.TERM) catch {};
        for (0..50) |_| {
            const res = posix.waitpid(self.child.id, std.c.W.NOHANG);
            if (res.pid != 0) {
                self.exit_status = res.status;
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        // Still alive after 500ms — force kill.
        if (self.exit_status == null) {
            posix.kill(self.child.id, posix.SIG.KILL) catch {};
            for (0..10) |_| {
                const res = posix.waitpid(self.child.id, std.c.W.NOHANG);
                if (res.pid != 0) break;
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    // Close pipe fds directly — avoid child.wait() which can block.
    if (self.child.stdout) |stdout| posix.close(stdout.handle);
    if (self.child.stderr) |stderr| posix.close(stderr.handle);

    self.stdout_buf.deinit(self.allocator);
    self.stderr_buf.deinit(self.allocator);
    for (self.lines.items) |line| {
        self.allocator.free(line);
    }
    self.lines.deinit(self.allocator);
    if (self.env_map) |*em| {
        em.deinit();
    }
}

fn readAvailable(fd: posix.fd_t, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &tmp) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
}

// --- Tests ---

const testing = std.testing;

fn waitForExit(proc: *Process, max_attempts: usize) void {
    for (0..max_attempts) |_| {
        if (proc.checkExit() != null) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

test "spawn echo and drain stdout" {
    var cmd = Cmd.init(testing.allocator, "/bin/echo");
    defer cmd.deinit();
    try cmd.arg("hello");

    var proc = try Process.spawn(testing.allocator, &cmd, .{});
    defer proc.deinit();

    waitForExit(&proc, 50);

    const lines = try proc.drainStdout();
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("hello", lines[0]);
}

test "multi-line stdout" {
    var cmd = Cmd.init(testing.allocator, "/bin/sh");
    defer cmd.deinit();
    try cmd.arg("-c");
    try cmd.arg("printf 'line1\\nline2\\nline3\\n'");

    var proc = try Process.spawn(testing.allocator, &cmd, .{});
    defer proc.deinit();

    waitForExit(&proc, 50);

    const lines = try proc.drainStdout();
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("line1", lines[0]);
    try testing.expectEqualStrings("line2", lines[1]);
    try testing.expectEqualStrings("line3", lines[2]);
}

test "stderr capture" {
    var cmd = Cmd.init(testing.allocator, "/bin/sh");
    defer cmd.deinit();
    try cmd.arg("-c");
    try cmd.arg("echo errmsg >&2");

    var proc = try Process.spawn(testing.allocator, &cmd, .{});
    defer proc.deinit();

    waitForExit(&proc, 50);

    const stderr = try proc.drainStderr();
    try testing.expect(std.mem.indexOf(u8, stderr, "errmsg") != null);
}

test "exit code 0" {
    var cmd = Cmd.init(testing.allocator, "/usr/bin/true");
    defer cmd.deinit();

    var proc = try Process.spawn(testing.allocator, &cmd, .{});
    defer proc.deinit();

    waitForExit(&proc, 50);

    try testing.expectEqual(@as(u32, 0), proc.checkExit().?);
}

test "exit code non-zero" {
    var cmd = Cmd.init(testing.allocator, "/usr/bin/false");
    defer cmd.deinit();

    var proc = try Process.spawn(testing.allocator, &cmd, .{});
    defer proc.deinit();

    waitForExit(&proc, 50);

    try testing.expectEqual(@as(u32, 1), proc.checkExit().?);
}

test "kill running process" {
    var cmd = Cmd.init(testing.allocator, "/bin/sleep");
    defer cmd.deinit();
    try cmd.arg("60");

    var proc = try Process.spawn(testing.allocator, &cmd, .{});
    defer proc.deinit();

    // Process should be running
    try testing.expect(proc.checkExit() == null);

    proc.kill();
    // deinit will wait for the process — no hang
}
