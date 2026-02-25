const std = @import("std");
const Cmd = @import("Cmd");
const ProcessPool = @import("ProcessPool");
const Memory = @import("Memory");
const Claude = @import("claude");
const prompts = @import("prompts");

pub fn run(args: *std.process.ArgIterator) void {
    const w = std.fs.File.stdout().deprecatedWriter();
    const e = std.fs.File.stderr().deprecatedWriter();

    const sub = args.next() orelse {
        e.writeAll("usage: cld provider [--claude \"prompt\" | --compact]\n") catch {};
        return;
    };

    if (std.mem.eql(u8, sub, "--claude")) {
        const prompt = args.next() orelse {
            e.writeAll("usage: cld provider --claude \"prompt\"\n") catch {};
            return;
        };
        runOneShot(w, e, prompt);
    } else if (std.mem.eql(u8, sub, "--compact")) {
        runCompact(w, e);
    } else {
        e.print("unknown provider option: {s}\n", .{sub}) catch {};
        e.writeAll("usage: cld provider [--claude \"prompt\" | --compact]\n") catch {};
    }
}

fn runOneShot(w: anytype, e: anytype, prompt: []const u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cmd = Cmd.init(allocator, "claude");
    defer cmd.deinit();
    cmd.arg("-p") catch return;
    cmd.arg(prompt) catch return;
    cmd.option("--output-format", "json") catch return;
    cmd.arg("--dangerously-skip-permissions") catch return;
    cmd.envRemove("CLAUDECODE") catch return;

    var result = ProcessPool.exec(allocator, &cmd) catch |err| {
        e.print("failed to run claude: {}\n", .{err}) catch {};
        return;
    };
    defer result.deinit();

    if (result.exit_code != 0) {
        e.print("claude exited with code {d}\n", .{result.exit_code}) catch {};
        if (result.stderr.len > 0) {
            e.print("{s}\n", .{result.stderr}) catch {};
        }
        return;
    }

    // Parse JSON output lines, find the result
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (Memory.parseClaudeResult(allocator, line)) |text| {
            defer allocator.free(text);
            w.print("{s}\n", .{text}) catch {};
            return;
        }
    }

    e.writeAll("no result in claude output\n") catch {};
}

fn runCompact(w: anytype, e: anytype) void {
    _ = e;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = ProcessPool.init(allocator);
    defer pool.deinit();

    // Resolve memory path: ~/.local/share/cld/memory
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME not set", .{});
        return;
    };
    const memory_path = std.fs.path.join(allocator, &.{ home, ".local", "share", "cld", "memory" }) catch return;
    defer allocator.free(memory_path);

    std.fs.cwd().makePath(memory_path) catch {};

    var memory = Memory.init(allocator, memory_path);
    defer memory.deinit();

    var claude = Claude.init(allocator, &pool);
    defer claude.deinit();

    const yesterday = Memory.yesterdayStr();
    const today = Memory.todayStr();

    claude.compact(&memory, &yesterday);
    claude.compact(&memory, &today);

    w.print("compaction done ({s}, {s})\n", .{ yesterday, today }) catch {};
}
